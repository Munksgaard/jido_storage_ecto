defmodule Jido.Storage.Ecto do
  @moduledoc """
  PostgreSQL storage adapter for Jido agent checkpoints and thread journals.

  Uses Ecto with PostgreSQL for durable, ACID-compliant storage that survives
  restarts and deployments.

  ## Usage

      defmodule MyApp.Jido do
        use Jido,
          otp_app: :my_app,
          storage: {Jido.Storage.Ecto, repo: MyApp.Repo}
      end

  ## Options

  - `:repo` - Ecto.Repo module (required)
  - `:prefix` - PostgreSQL schema name (default: `"public"`)
  - `:format` - Data serialization format (default: `:json`)
    - `:json` — Human-readable, queryable via jsonb. Atom keys are restored
      on read using `String.to_existing_atom/1` (safe). Atom _values_ become
      strings — handle this in your `restore/2` callback. Structs are converted
      to plain maps. Values that are not JSON-serializable (PIDs, references,
      functions, non-UTF8 binaries) will cause an error — use `:binary` format
      for data containing such values.
    - `:binary` — Lossless round-trip via `:erlang.term_to_binary`. Opaque
      in the database but preserves atoms, tuples, and structs exactly.
      Decoded with `[:safe]` flag to prevent atom table exhaustion.

  ## Setup

  1. Add the dependency and run `mix deps.get`
  2. Generate and run a migration:

         mix ecto.gen.migration add_jido_storage

      ```elixir
      defmodule MyApp.Repo.Migrations.AddJidoStorage do
        use Ecto.Migration

        def up, do: Jido.Storage.Ecto.Migration.up()
        def down, do: Jido.Storage.Ecto.Migration.down()
      end
      ```

  3. Configure your Jido instance:

      ```elixir
      storage: {Jido.Storage.Ecto, repo: MyApp.Repo}
      ```

  ## PostgreSQL Schema Isolation

  Use the `:prefix` option for multi-tenant or namespaced deployments:

      storage: {Jido.Storage.Ecto, repo: MyApp.Repo, prefix: "jido"}

  The prefix maps to a PostgreSQL schema. Run migrations with the same prefix:

      Jido.Storage.Ecto.Migration.up(prefix: "jido")

  ## Concurrency

  Thread appends use PostgreSQL advisory locks (`pg_advisory_xact_lock`) within
  a transaction for safe concurrent access. The `:expected_rev` option in
  `append_thread/3` provides optimistic concurrency control. A lock timeout
  (default 5 seconds) prevents indefinite blocking under contention.

  ## Performance Considerations

  - Each `append_thread/3` returns the full thread. For threads exceeding
    ~10,000 entries, consider archiving older entries or paginating reads
    in your application layer.

  - Size your Ecto connection pool to at least the expected number of
    concurrent thread writers. Each `append_thread` holds a connection
    for the duration of its write transaction.

  - `load_thread/2` reads all entries in a single query. For very large
    threads, consider implementing pagination or limiting entry retrieval
    in your application layer.

  - The `:format` option should be consistent for all operations within
    a deployment. Mixing formats within a thread is supported via fallback
    decoding but is not recommended.

  - For payloads with many unique string keys that aren't existing atoms,
    `:binary` format avoids per-key atom lookup overhead on reads.
  """

  @behaviour Jido.Storage

  import Ecto.Query

  alias Jido.Storage.Ecto.Checkpoint
  alias Jido.Storage.Ecto.ThreadEntry
  alias Jido.Storage.Ecto.ThreadMeta
  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @default_prefix "public"
  @default_format :json
  @default_lock_timeout "5s"
  @lock_namespace :erlang.phash2("jido_storage_thread")

  # =============================================================================
  # Checkpoint Operations
  # =============================================================================

  @impl true
  def get_checkpoint(key, opts) do
    with {:ok, repo} <- repo(opts),
         {:ok, format} <- format(opts) do
      prefix = prefix(opts)
      encoded_key = encode_key(key)

      # Explicitly return `:not_found` here, as per spec.
      case repo.get(Checkpoint, encoded_key, prefix: prefix) do
        nil -> :not_found
        record -> decode_checkpoint_data(record, format)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def put_checkpoint(key, data, opts) do
    with {:ok, repo} <- repo(opts),
         {:ok, format} <- format(opts),
         prefix = prefix(opts),
         encoded_key = encode_key(key),
         now = DateTime.utc_now(),
         {json_data, binary_data} = encode_data(data, format),
         attrs = %{
           key: encoded_key,
           key_display: display_key(key),
           data: json_data,
           data_binary: binary_data,
           inserted_at: now,
           updated_at: now
         },
         {:ok, _} <-
           repo.insert(
             struct(Checkpoint, attrs),
             prefix: prefix,
             on_conflict: [
               set: [
                 data: json_data,
                 data_binary: binary_data,
                 key_display: attrs.key_display,
                 updated_at: now
               ]
             ],
             conflict_target: :key
           ) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def delete_checkpoint(key, opts) do
    with {:ok, repo} <- repo(opts) do
      prefix = prefix(opts)
      encoded_key = encode_key(key)

      Checkpoint
      |> where([c], c.key == ^encoded_key)
      |> repo.delete_all(prefix: prefix)

      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  # =============================================================================
  # Thread Operations
  # =============================================================================

  @impl true
  def load_thread(thread_id, opts) do
    with {:ok, repo} <- repo(opts),
         {:ok, format} <- format(opts) do
      prefix = prefix(opts)

      # Wrap in a transaction so both queries see the same MVCC snapshot,
      # preventing inconsistency if a concurrent write commits between them.
      case repo.transaction(fn ->
             case load_entries(repo, prefix, format, thread_id) do
               {:error, reason} ->
                 repo.rollback(reason)

               {:ok, []} ->
                 repo.rollback(:not_found)

               {:ok, entries} ->
                 case load_meta(repo, prefix, format, thread_id) do
                   {:error, reason} -> repo.rollback(reason)
                   meta -> reconstruct_thread(thread_id, entries, meta)
                 end
             end
           end) do
        {:ok, thread} -> {:ok, thread}
        {:error, :not_found} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def append_thread(thread_id, [] = _entries, opts) do
    # Short-circuit: no entries to append. Load existing thread or return not_found.
    # This avoids creating orphan meta rows.
    case load_thread(thread_id, opts) do
      {:ok, thread} -> {:ok, thread}
      :not_found -> {:ok, empty_thread(thread_id)}
      {:error, _reason} = error -> error
    end
  end

  def append_thread(thread_id, entries, opts) do
    with {:ok, repo} <- repo(opts),
         {:ok, format} <- format(opts) do
      prefix = prefix(opts)
      expected_rev = Keyword.get(opts, :expected_rev)
      metadata = Keyword.get(opts, :metadata)

      # The transaction holds the advisory lock only for the write operations.
      # The full thread reload happens outside the lock to minimize contention.
      result =
        repo.transaction(fn ->
          # Acquire transaction-scoped advisory lock for this thread
          acquire_thread_lock(repo, prefix, thread_id)

          # Compute timestamp after lock acquisition so entry timestamps
          # reflect commit order, not request order under contention.
          now = System.system_time(:millisecond)

          # Read current state under lock
          current_meta = load_meta(repo, prefix, format, thread_id)
          current_rev = if current_meta, do: current_meta.rev, else: 0

          # Optimistic concurrency check and write operations
          with :ok <- validate_expected_rev(expected_rev, current_rev),
               :ok <-
                 insert_entries(
                   repo,
                   prefix,
                   format,
                   thread_id,
                   EntryNormalizer.normalize_many(entries, current_rev, now)
                 ),
               :ok <-
                 upsert_meta(
                   repo,
                   prefix,
                   format,
                   thread_id,
                   current_rev + length(entries),
                   now,
                   current_rev == 0,
                   metadata
                 ) do
            :ok
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} ->
          # Reload thread outside the lock — this is a consistent read via
          # load_thread's own transaction, and minimizes advisory lock hold time.
          load_thread(thread_id, opts)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def delete_thread(thread_id, opts) do
    with {:ok, repo} <- repo(opts) do
      prefix = prefix(opts)

      case repo.transaction(fn ->
             # Acquire advisory lock to prevent races with concurrent appends
             acquire_thread_lock(repo, prefix, thread_id)

             ThreadEntry
             |> where([e], e.thread_id == ^thread_id)
             |> repo.delete_all(prefix: prefix)

             ThreadMeta
             |> where([m], m.thread_id == ^thread_id)
             |> repo.delete_all(prefix: prefix)
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # =============================================================================
  # Private: Config Extraction
  # =============================================================================

  defp repo(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} ->
        {:ok, repo}

      :error ->
        {:error,
         %ArgumentError{
           message:
             "Jido.Storage.Ecto requires a :repo option. " <>
               "Example: {Jido.Storage.Ecto, repo: MyApp.Repo}"
         }}
    end
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix, @default_prefix)

  defp format(opts) do
    case Keyword.get(opts, :format, @default_format) do
      f when f in [:json, :binary] ->
        {:ok, f}

      other ->
        {:error,
         %ArgumentError{
           message: "invalid :format option #{inspect(other)}, expected :json or :binary"
         }}
    end
  end

  # =============================================================================
  # Private: Key Encoding
  # =============================================================================

  defp encode_key(key) do
    key |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  end

  defp display_key(key) do
    inspect(key, limit: 50, printable_limit: 1000)
  end

  # =============================================================================
  # Private: Data Encoding/Decoding
  # =============================================================================

  # Returns {json_value | nil, binary_value | nil}
  defp encode_data(data, :json), do: {ensure_json_safe(data), nil}
  defp encode_data(data, :binary), do: {nil, :erlang.term_to_binary(data)}

  defp decode_checkpoint_data(record, preferred_format) do
    case preferred_format do
      :json when not is_nil(record.data) -> {:ok, atomize_keys(record.data)}
      :binary when not is_nil(record.data_binary) -> decode_binary(record.data_binary)
      # Fallback: try whichever column has data
      _ when not is_nil(record.data) -> {:ok, atomize_keys(record.data)}
      _ when not is_nil(record.data_binary) -> decode_binary(record.data_binary)
      _ -> {:ok, nil}
    end
  end

  # Encode a value into {json_column, binary_column} based on format.
  # Used for entry payloads, entry refs, and thread metadata.
  defp encode_value(value, :json), do: {ensure_json_safe(value), nil}
  defp encode_value(value, :binary), do: {nil, :erlang.term_to_binary(value)}

  defp decode_entry_payload(record, preferred_format) do
    case preferred_format do
      :json when not is_nil(record.payload) -> {:ok, atomize_keys(record.payload)}
      :binary when not is_nil(record.payload_binary) -> decode_binary(record.payload_binary)
      _ when not is_nil(record.payload) -> {:ok, atomize_keys(record.payload)}
      _ when not is_nil(record.payload_binary) -> decode_binary(record.payload_binary)
      _ -> {:ok, %{}}
    end
  end

  defp decode_entry_refs(record, preferred_format) do
    case preferred_format do
      :json when not is_nil(record.refs) -> {:ok, atomize_keys(record.refs)}
      :binary when not is_nil(record.refs_binary) -> decode_binary(record.refs_binary)
      _ when not is_nil(record.refs) -> {:ok, atomize_keys(record.refs)}
      _ when not is_nil(record.refs_binary) -> decode_binary(record.refs_binary)
      _ -> {:ok, %{}}
    end
  end

  defp decode_meta_metadata(record, preferred_format) do
    case preferred_format do
      :json when not is_nil(record.metadata) -> {:ok, atomize_keys(record.metadata)}
      :binary when not is_nil(record.metadata_binary) -> decode_binary(record.metadata_binary)
      _ when not is_nil(record.metadata) -> {:ok, atomize_keys(record.metadata)}
      _ when not is_nil(record.metadata_binary) -> decode_binary(record.metadata_binary)
      _ -> {:ok, %{}}
    end
  end

  defp decode_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> {:error, :corrupted_data}
  end

  # Ensure data is JSON-serializable. Atoms become strings, tuples become lists.
  # Structs are converted to plain maps with the __struct__ key removed.
  defp ensure_json_safe(%_{} = data) do
    data |> Map.from_struct() |> ensure_json_safe()
  end

  defp ensure_json_safe(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_json_key(k), ensure_json_safe(v)} end)
  end

  defp ensure_json_safe(data) when is_list(data), do: Enum.map(data, &ensure_json_safe/1)

  defp ensure_json_safe(data) when is_tuple(data),
    do: data |> Tuple.to_list() |> ensure_json_safe()

  defp ensure_json_safe(data) when is_atom(data) and not is_nil(data) and not is_boolean(data),
    do: Atom.to_string(data)

  defp ensure_json_safe(data), do: data

  defp to_json_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_json_key(k) when is_binary(k), do: k
  defp to_json_key(k), do: inspect(k)

  # Recursively convert string map keys to existing atoms where possible.
  # Keys that don't correspond to existing atoms are left as strings.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_existing_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  defp safe_to_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  # =============================================================================
  # Private: Thread Helpers
  # =============================================================================

  defp acquire_thread_lock(repo, prefix, thread_id) do
    # Set a lock timeout to prevent indefinite blocking under contention.
    # Uses SET LOCAL so it only applies to this transaction.
    repo.query!("SET LOCAL lock_timeout = '#{@default_lock_timeout}'")

    # Use two-argument pg_advisory_xact_lock for good hash distribution.
    # Lock is automatically released when the transaction ends.
    key = :erlang.phash2({prefix, thread_id})
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, key])
  end

  defp validate_expected_rev(nil, _current_rev), do: :ok
  defp validate_expected_rev(expected, actual) when expected === actual, do: :ok
  defp validate_expected_rev(_expected, _actual), do: {:error, :conflict}

  defp load_entries(repo, prefix, format, thread_id) do
    records =
      ThreadEntry
      |> where([e], e.thread_id == ^thread_id)
      |> order_by([e], asc: e.seq)
      |> repo.all(prefix: prefix)

    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case record_to_entry(record, format) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_meta(repo, prefix, format, thread_id) do
    case repo.get(ThreadMeta, thread_id, prefix: prefix) do
      nil ->
        nil

      record ->
        case decode_meta_metadata(record, format) do
          {:ok, metadata} ->
            %{
              rev: record.rev,
              metadata: metadata,
              created_at: record.created_at,
              updated_at: record.updated_at
            }

          {:error, _} = err ->
            err
        end
    end
  end

  # PostgreSQL parameter limit is 65535. Each entry row has ~10 params,
  # so we batch at 6000 to stay well under the limit.
  @insert_batch_size 6000

  defp insert_entries(_repo, _prefix, _format, _thread_id, []), do: :ok

  defp insert_entries(repo, prefix, format, thread_id, entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn entry ->
        {payload_json, payload_binary} = encode_value(entry.payload, format)
        {refs_json, refs_binary} = encode_value(entry.refs, format)

        %{
          thread_id: thread_id,
          seq: entry.seq,
          entry_id: entry.id,
          kind: to_string(entry.kind),
          at: entry.at,
          payload: payload_json,
          payload_binary: payload_binary,
          refs: refs_json,
          refs_binary: refs_binary,
          inserted_at: now
        }
      end)

    total_inserted =
      rows
      |> Enum.chunk_every(@insert_batch_size)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} = repo.insert_all(ThreadEntry, chunk, prefix: prefix)
        acc + count
      end)

    expected = length(entries)

    if total_inserted != expected do
      {:error, {:insert_count_mismatch, expected: expected, actual: total_inserted}}
    else
      :ok
    end
  end

  defp upsert_meta(repo, prefix, format, thread_id, new_rev, now, is_new, metadata) do
    # When metadata is nil (not explicitly provided), preserve existing metadata.
    # When metadata is a map (explicitly provided, even %{}), overwrite it.
    {meta_json, meta_binary} =
      if metadata != nil, do: encode_value(metadata, format), else: {nil, nil}

    if is_new do
      # For new threads, default metadata to %{} if not provided
      {insert_json, insert_binary} =
        if metadata != nil, do: {meta_json, meta_binary}, else: encode_value(%{}, format)

      case struct(ThreadMeta, %{
             thread_id: thread_id,
             rev: new_rev,
             metadata: insert_json,
             metadata_binary: insert_binary,
             created_at: now,
             updated_at: now
           })
           |> repo.insert(
             prefix: prefix,
             on_conflict: meta_conflict_set(new_rev, now, meta_json, meta_binary),
             conflict_target: :thread_id
           ) do
        {:ok, _} -> :ok
        {:error, changeset} -> {:error, {:meta_insert_failed, changeset}}
      end
    else
      case ThreadMeta
           |> where([m], m.thread_id == ^thread_id)
           |> repo.update_all(
             [set: meta_update_set(new_rev, now, meta_json, meta_binary)],
             prefix: prefix
           ) do
        {count, _} when count > 0 -> :ok
        {0, _} -> {:error, {:meta_update_failed, thread_id}}
      end
    end
  end

  # Build the SET clause for meta updates, including metadata only when explicitly provided.
  defp meta_update_set(new_rev, now, nil, nil) do
    [rev: new_rev, updated_at: now]
  end

  defp meta_update_set(new_rev, now, meta_json, meta_binary) do
    [rev: new_rev, metadata: meta_json, metadata_binary: meta_binary, updated_at: now]
  end

  # Build the on_conflict SET clause, including metadata only when explicitly provided.
  defp meta_conflict_set(new_rev, now, nil, nil) do
    [set: [rev: new_rev, updated_at: now]]
  end

  defp meta_conflict_set(new_rev, now, meta_json, meta_binary) do
    [set: [rev: new_rev, metadata: meta_json, metadata_binary: meta_binary, updated_at: now]]
  end

  defp record_to_entry(record, format) do
    with {:ok, payload} <- decode_entry_payload(record, format),
         {:ok, refs} <- decode_entry_refs(record, format) do
      {:ok,
       %Entry{
         id: record.entry_id,
         seq: record.seq,
         at: record.at,
         # kind is always stored as an atom-derived string (via to_string/1 in
         # insert_entries), so converting back is safe — the atom existed when stored.
         kind: String.to_atom(record.kind),
         payload: payload,
         refs: refs
       }}
    end
  end

  defp empty_thread(thread_id) do
    now = System.system_time(:millisecond)

    %Thread{
      id: thread_id,
      rev: 0,
      entries: [],
      created_at: now,
      updated_at: now,
      metadata: %{},
      stats: %{entry_count: 0}
    }
  end

  defp reconstruct_thread(thread_id, entries, meta) do
    entry_count = length(entries)
    # Use meta.rev when available (source of truth for optimistic concurrency),
    # fall back to entry_count for threads without meta.
    rev = if meta, do: meta.rev, else: entry_count
    first_entry = List.first(entries)
    last_entry = List.last(entries)

    %Thread{
      id: thread_id,
      rev: rev,
      entries: entries,
      created_at: (meta && meta.created_at) || (first_entry && first_entry.at),
      updated_at: (meta && meta.updated_at) || (last_entry && last_entry.at),
      metadata: (meta && meta.metadata) || %{},
      stats: %{entry_count: entry_count}
    }
  end
end
