defmodule Jido.Storage.EctoTest do
  use JidoStorageEcto.DataCase, async: true

  alias Jido.Storage
  alias Jido.Storage.Ecto, as: EctoStorage
  alias Jido.Thread
  alias Jido.Thread.Entry

  @repo JidoStorageEcto.TestRepo

  defp opts(extra \\ []) do
    Keyword.merge([repo: @repo], extra)
  end

  # ===========================================================================
  # Checkpoint Operations
  # ===========================================================================

  describe "get_checkpoint/2" do
    test "returns :not_found for missing key" do
      assert :not_found = EctoStorage.get_checkpoint(:nonexistent_key, opts())
    end
  end

  describe "put_checkpoint/3 and get_checkpoint/2" do
    test "stores and retrieves data" do
      key = {TestAgent, "put-get-#{System.unique_integer([:positive])}"}
      data = %{state: "saved", version: 1}

      assert :ok = EctoStorage.put_checkpoint(key, data, opts())
      assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, opts())
      assert retrieved[:state] == "saved"
      assert retrieved[:version] == 1
    end

    test "overwrites existing data" do
      key = {TestAgent, "overwrite-#{System.unique_integer([:positive])}"}

      assert :ok = EctoStorage.put_checkpoint(key, %{version: 1}, opts())
      assert {:ok, %{version: 1}} = EctoStorage.get_checkpoint(key, opts())

      assert :ok = EctoStorage.put_checkpoint(key, %{version: 2}, opts())
      assert {:ok, %{version: 2}} = EctoStorage.get_checkpoint(key, opts())
    end

    test "supports various key types" do
      keys = [
        "string_key_#{System.unique_integer([:positive])}",
        {:tuple, :key, System.unique_integer([:positive])},
        System.unique_integer([:positive])
      ]

      for key <- keys do
        data = %{key_type: inspect(key)}
        assert :ok = EctoStorage.put_checkpoint(key, data, opts())
        assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, opts())
        assert retrieved[:key_type] == inspect(key)
      end
    end
  end

  describe "delete_checkpoint/2" do
    test "removes data" do
      key = {TestAgent, "delete-#{System.unique_integer([:positive])}"}

      assert :ok = EctoStorage.put_checkpoint(key, %{data: "exists"}, opts())
      assert {:ok, _} = EctoStorage.get_checkpoint(key, opts())

      assert :ok = EctoStorage.delete_checkpoint(key, opts())
      assert :not_found = EctoStorage.get_checkpoint(key, opts())
    end

    test "succeeds even if key doesn't exist" do
      key = {TestAgent, "never-existed-#{System.unique_integer([:positive])}"}
      assert :ok = EctoStorage.delete_checkpoint(key, opts())
    end
  end

  # ===========================================================================
  # JSON Format (default)
  # ===========================================================================

  describe "json format" do
    test "atomizes known keys in checkpoint data" do
      key = {TestAgent, "json-atoms-#{System.unique_integer([:positive])}"}

      data = %{
        version: 1,
        agent_module: SomeModule,
        id: "test-123",
        state: %{counter: 42},
        thread: %{id: "thread_abc", rev: 2}
      }

      assert :ok = EctoStorage.put_checkpoint(key, data, opts())
      assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, opts())

      # Top-level keys should be atoms (they exist in the atom table)
      assert retrieved[:version] == 1
      assert retrieved[:id] == "test-123"
      assert retrieved[:state] == %{counter: 42}

      # Nested thread pointer keys should be atoms
      assert retrieved[:thread][:id] == "thread_abc"
      assert retrieved[:thread][:rev] == 2

      # Atom values become strings in JSON
      assert is_binary(retrieved[:agent_module])
    end

    test "complex nested data survives json round-trip" do
      key = {TestAgent, "json-complex-#{System.unique_integer([:positive])}"}

      data = %{
        string: "hello",
        integer: 123,
        float: 3.14,
        list: [1, 2, 3],
        nested: %{deep: %{value: true}},
        nil_val: nil,
        bool: false
      }

      assert :ok = EctoStorage.put_checkpoint(key, data, opts())
      assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, opts())

      assert retrieved[:string] == "hello"
      assert retrieved[:integer] == 123
      assert retrieved[:float] == 3.14
      assert retrieved[:list] == [1, 2, 3]
      assert retrieved[:nested] == %{deep: %{value: true}}
      assert retrieved[:nil_val] == nil
      assert retrieved[:bool] == false
    end
  end

  # ===========================================================================
  # Binary Format
  # ===========================================================================

  describe "binary format" do
    test "lossless round-trip for checkpoints" do
      key = {TestAgent, "binary-#{System.unique_integer([:positive])}"}

      data = %{
        atom_val: :active,
        tuple: {:ok, "value"},
        nested: %{atom_key: :test},
        status: :processing
      }

      bin_opts = opts(format: :binary)

      assert :ok = EctoStorage.put_checkpoint(key, data, bin_opts)
      assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, bin_opts)

      assert retrieved.atom_val == :active
      assert retrieved.tuple == {:ok, "value"}
      assert retrieved.nested == %{atom_key: :test}
      assert retrieved.status == :processing
    end

    test "lossless round-trip for thread entry payloads" do
      thread_id = "binary-thread-#{System.unique_integer([:positive])}"
      bin_opts = opts(format: :binary)

      entries = [
        %{kind: :message, payload: %{role: :user, tuple: {:ok, 42}}}
      ]

      assert {:ok, thread} = EctoStorage.append_thread(thread_id, entries, bin_opts)
      entry = hd(thread.entries)
      assert entry.payload.role == :user
      assert entry.payload.tuple == {:ok, 42}

      assert {:ok, loaded} = EctoStorage.load_thread(thread_id, bin_opts)
      loaded_entry = hd(loaded.entries)
      assert loaded_entry.payload.role == :user
      assert loaded_entry.payload.tuple == {:ok, 42}
    end
  end

  # ===========================================================================
  # Thread Operations
  # ===========================================================================

  describe "load_thread/2" do
    test "returns :not_found for missing thread" do
      assert :not_found = EctoStorage.load_thread("nonexistent_thread", opts())
    end
  end

  describe "append_thread/3" do
    test "creates thread with entries" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entries = [
        %{kind: :message, payload: %{role: "user", content: "Hello"}}
      ]

      assert {:ok, %Thread{} = thread} = EctoStorage.append_thread(thread_id, entries, opts())
      assert thread.id == thread_id
      assert thread.rev == 1
      assert length(thread.entries) == 1
      assert hd(thread.entries).kind == :message
    end

    test "appends to existing thread" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entry1 = %{kind: :message, payload: %{content: "First"}}
      entry2 = %{kind: :message, payload: %{content: "Second"}}

      {:ok, thread1} = EctoStorage.append_thread(thread_id, [entry1], opts())
      assert thread1.rev == 1

      {:ok, thread2} = EctoStorage.append_thread(thread_id, [entry2], opts())
      assert thread2.rev == 2
      assert length(thread2.entries) == 2
      assert Enum.at(thread2.entries, 0).payload[:content] == "First"
      assert Enum.at(thread2.entries, 1).payload[:content] == "Second"
    end

    test "with expected_rev: succeeds when rev matches" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      {:ok, thread1} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert thread1.rev == 1

      {:ok, thread2} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note}],
          Keyword.put(opts(), :expected_rev, 1)
        )

      assert thread2.rev == 2
    end

    test "with expected_rev: returns {:error, :conflict} when rev doesn't match" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())

      assert {:error, :conflict} =
               EctoStorage.append_thread(
                 thread_id,
                 [%{kind: :note}],
                 Keyword.put(opts(), :expected_rev, 0)
               )

      assert {:error, :conflict} =
               EctoStorage.append_thread(
                 thread_id,
                 [%{kind: :note}],
                 Keyword.put(opts(), :expected_rev, 5)
               )
    end

    test "assigns correct seq numbers" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entries = [
        %{kind: :note, payload: %{text: "First"}},
        %{kind: :note, payload: %{text: "Second"}},
        %{kind: :note, payload: %{text: "Third"}}
      ]

      {:ok, thread} = EctoStorage.append_thread(thread_id, entries, opts())

      assert Enum.at(thread.entries, 0).seq == 0
      assert Enum.at(thread.entries, 1).seq == 1
      assert Enum.at(thread.entries, 2).seq == 2

      {:ok, updated} =
        EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{text: "Fourth"}}], opts())

      assert Enum.at(updated.entries, 3).seq == 3
    end

    test "entries get unique IDs assigned" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entries = [
        %{kind: :message, payload: %{content: "One"}},
        %{kind: :message, payload: %{content: "Two"}}
      ]

      {:ok, thread} = EctoStorage.append_thread(thread_id, entries, opts())

      [e1, e2] = thread.entries
      assert is_binary(e1.id)
      assert is_binary(e2.id)
      assert String.starts_with?(e1.id, "entry_")
      assert String.starts_with?(e2.id, "entry_")
      refute e1.id == e2.id
    end

    test "entries get timestamps assigned" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      before = System.system_time(:millisecond)
      {:ok, thread} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      after_append = System.system_time(:millisecond)

      entry = hd(thread.entries)
      assert is_integer(entry.at)
      assert entry.at >= before
      assert entry.at <= after_append
    end

    test "accepts Entry structs directly" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entry = Entry.new(kind: :message, payload: %{role: "user", content: "Hello"})

      {:ok, thread} = EctoStorage.append_thread(thread_id, [entry], opts())
      assert length(thread.entries) == 1
      assert hd(thread.entries).kind == :message
    end

    test "thread metadata is preserved" do
      thread_id = "thread_#{System.unique_integer([:positive])}"
      meta_opts = Keyword.put(opts(), :metadata, %{user_id: "u123", session: "s456"})

      {:ok, thread} = EctoStorage.append_thread(thread_id, [%{kind: :note}], meta_opts)
      # Metadata atom keys become strings in JSON mode
      assert thread.metadata[:user_id] == "u123" or thread.metadata["user_id"] == "u123"

      {:ok, loaded} = EctoStorage.load_thread(thread_id, opts())
      assert loaded.metadata[:user_id] == "u123" or loaded.metadata["user_id"] == "u123"
    end

    test "thread has created_at and updated_at timestamps" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      before = System.system_time(:millisecond)
      {:ok, thread} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())

      assert is_integer(thread.created_at)
      assert is_integer(thread.updated_at)
      assert thread.created_at >= before
      assert thread.updated_at >= thread.created_at

      Process.sleep(2)

      {:ok, updated} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert updated.created_at == thread.created_at
      assert updated.updated_at >= thread.updated_at
    end

    test "stats include entry_count" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      {:ok, thread} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note}, %{kind: :note}, %{kind: :note}],
          opts()
        )

      assert thread.stats.entry_count == 3
    end
  end

  describe "load_thread/2 with data" do
    test "returns correct Thread with all entries" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entries = [
        %{kind: :message, payload: %{role: "user", content: "Hello"}},
        %{kind: :message, payload: %{role: "assistant", content: "Hi there"}},
        %{kind: :tool_call, payload: %{name: "search", args: %{}}}
      ]

      {:ok, _} = EctoStorage.append_thread(thread_id, entries, opts())

      assert {:ok, %Thread{} = thread} = EctoStorage.load_thread(thread_id, opts())
      assert thread.id == thread_id
      assert thread.rev == 3
      assert length(thread.entries) == 3

      [e0, e1, e2] = thread.entries
      assert e0.kind == :message
      assert e1.kind == :message
      assert e2.kind == :tool_call
    end
  end

  describe "delete_thread/2" do
    test "removes thread and all entries" do
      thread_id = "thread_#{System.unique_integer([:positive])}"

      entries = [
        %{kind: :message, payload: %{content: "Entry 1"}},
        %{kind: :message, payload: %{content: "Entry 2"}}
      ]

      {:ok, _} = EctoStorage.append_thread(thread_id, entries, opts())
      assert {:ok, _} = EctoStorage.load_thread(thread_id, opts())

      assert :ok = EctoStorage.delete_thread(thread_id, opts())
      assert :not_found = EctoStorage.load_thread(thread_id, opts())
    end

    test "succeeds even if thread doesn't exist" do
      assert :ok = EctoStorage.delete_thread("never_existed_thread", opts())
    end
  end

  # ===========================================================================
  # Concurrency
  # ===========================================================================

  describe "concurrent append" do
    test "assigns unique contiguous sequence numbers under concurrency" do
      thread_id = "thread_#{System.unique_integer([:positive])}"
      total_appends = 20
      parent = self()

      # Seed the thread
      {:ok, _} =
        EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 0}}], opts())

      results =
        1..total_appends
        |> Task.async_stream(
          fn i ->
            Ecto.Adapters.SQL.Sandbox.allow(JidoStorageEcto.TestRepo, parent, self())

            EctoStorage.append_thread(
              thread_id,
              [%{kind: :note, payload: %{n: i}}],
              opts()
            )
          end,
          max_concurrency: 10,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, _thread}} -> true
               _ -> false
             end)

      assert {:ok, thread} = EctoStorage.load_thread(thread_id, opts())
      assert thread.rev == total_appends + 1

      seqs = Enum.map(thread.entries, & &1.seq)
      assert seqs == Enum.to_list(0..total_appends)
      assert Enum.uniq(seqs) == seqs
    end

    test "with expected_rev allows only one concurrent writer" do
      thread_id = "thread_#{System.unique_integer([:positive])}"
      parent = self()

      {:ok, first} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert first.rev == 1

      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(JidoStorageEcto.TestRepo, parent, self())

            EctoStorage.append_thread(
              thread_id,
              [%{kind: :note}],
              Keyword.put(opts(), :expected_rev, 1)
            )
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      conflict_count = Enum.count(results, &(&1 == {:error, :conflict}))

      assert ok_count == 1
      assert conflict_count == 1
    end
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  describe "edge cases" do
    test "appending empty entries list to non-existent thread returns empty thread" do
      thread_id = "empty-append-#{System.unique_integer([:positive])}"

      {:ok, thread} = EctoStorage.append_thread(thread_id, [], opts())
      assert thread.id == thread_id
      assert thread.rev == 0
      assert thread.entries == []
    end

    test "appending empty entries list to existing thread returns existing thread" do
      thread_id = "empty-existing-#{System.unique_integer([:positive])}"

      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      {:ok, thread} = EctoStorage.append_thread(thread_id, [], opts())
      assert thread.rev == 1
      assert length(thread.entries) == 1
    end

    test "load_thread after multiple sequential appends returns all entries" do
      thread_id = "multi-append-#{System.unique_integer([:positive])}"

      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 1}}], opts())
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 2}}], opts())
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 3}}], opts())

      {:ok, loaded} = EctoStorage.load_thread(thread_id, opts())
      assert loaded.rev == 3
      assert length(loaded.entries) == 3
      assert Enum.map(loaded.entries, & &1.seq) == [0, 1, 2]
    end

    test "delete_thread removes meta row (subsequent append starts fresh)" do
      thread_id = "delete-meta-#{System.unique_integer([:positive])}"

      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert :ok = EctoStorage.delete_thread(thread_id, opts())

      # Appending after delete should start from seq 0 / rev 0
      {:ok, thread} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert thread.rev == 1
      assert hd(thread.entries).seq == 0
    end

    test "missing :repo option returns error" do
      # repo/1 returns {:error, %ArgumentError{}} which propagates via the with chain
      assert {:error, %ArgumentError{}} = EctoStorage.get_checkpoint(:some_key, [])
      assert {:error, %ArgumentError{}} = EctoStorage.put_checkpoint(:k, %{}, [])
      assert {:error, %ArgumentError{}} = EctoStorage.load_thread("t", [])
    end
  end

  # ===========================================================================
  # Binary Format - Additional Coverage
  # ===========================================================================

  describe "binary format refs round-trip" do
    test "entry refs survive binary round-trip" do
      thread_id = "binary-refs-#{System.unique_integer([:positive])}"
      bin_opts = opts(format: :binary)

      entries = [
        %{
          kind: :tool_call,
          payload: %{name: "search"},
          refs: %{signal_id: "sig_123", action: SomeAction}
        }
      ]

      {:ok, _} = EctoStorage.append_thread(thread_id, entries, bin_opts)

      {:ok, loaded} = EctoStorage.load_thread(thread_id, bin_opts)
      entry = hd(loaded.entries)
      assert entry.refs.signal_id == "sig_123"
      assert entry.refs.action == SomeAction
    end
  end

  # ===========================================================================
  # Prefix / Schema Isolation
  # ===========================================================================

  describe "prefix option" do
    # Prefix schema + tables created in test_helper.exs before sandbox starts

    test "checkpoints are isolated by prefix" do
      key = {TestAgent, "prefix-test-#{System.unique_integer([:positive])}"}
      public_opts = opts()
      prefixed_opts = opts(prefix: "jido_test_prefix")

      :ok = EctoStorage.put_checkpoint(key, %{location: "public"}, public_opts)
      :ok = EctoStorage.put_checkpoint(key, %{location: "prefixed"}, prefixed_opts)

      {:ok, pub} = EctoStorage.get_checkpoint(key, public_opts)
      {:ok, pre} = EctoStorage.get_checkpoint(key, prefixed_opts)

      assert pub[:location] == "public"
      assert pre[:location] == "prefixed"
    end

    test "threads are isolated by prefix" do
      thread_id = "prefix-thread-#{System.unique_integer([:positive])}"
      public_opts = opts()
      prefixed_opts = opts(prefix: "jido_test_prefix")

      {:ok, _} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note, payload: %{from: "public"}}],
          public_opts
        )

      {:ok, _} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note, payload: %{from: "prefixed"}}],
          prefixed_opts
        )

      {:ok, pub} = EctoStorage.load_thread(thread_id, public_opts)
      {:ok, pre} = EctoStorage.load_thread(thread_id, prefixed_opts)

      assert length(pub.entries) == 1
      assert length(pre.entries) == 1
      assert hd(pub.entries).payload[:from] == "public"
      assert hd(pre.entries).payload[:from] == "prefixed"
    end
  end

  # ===========================================================================
  # Metadata update on subsequent appends (Issue #1/#19)
  # ===========================================================================

  describe "metadata updates" do
    test "metadata is updated on subsequent appends" do
      thread_id = "meta-update-#{System.unique_integer([:positive])}"

      initial_opts = Keyword.put(opts(), :metadata, %{user_id: "u123"})
      {:ok, thread1} = EctoStorage.append_thread(thread_id, [%{kind: :note}], initial_opts)
      assert thread1.metadata[:user_id] == "u123"

      updated_opts = Keyword.put(opts(), :metadata, %{user_id: "u456", session: "s789"})
      {:ok, thread2} = EctoStorage.append_thread(thread_id, [%{kind: :note}], updated_opts)
      assert thread2.metadata[:user_id] == "u456"
      assert thread2.metadata[:session] == "s789"

      # Verify it persists on reload
      {:ok, loaded} = EctoStorage.load_thread(thread_id, opts())
      assert loaded.metadata[:user_id] == "u456"
      assert loaded.metadata[:session] == "s789"
    end

    test "metadata is preserved when not provided on subsequent appends" do
      thread_id = "meta-preserve-#{System.unique_integer([:positive])}"

      initial_opts = Keyword.put(opts(), :metadata, %{user_id: "u123"})
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], initial_opts)

      # Append without metadata option — existing metadata is preserved
      {:ok, thread2} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())
      assert thread2.metadata[:user_id] == "u123"
    end

    test "metadata is cleared when explicitly set to empty map" do
      thread_id = "meta-clear-#{System.unique_integer([:positive])}"

      initial_opts = Keyword.put(opts(), :metadata, %{user_id: "u123"})
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], initial_opts)

      # Explicitly pass empty metadata — this overwrites
      clear_opts = Keyword.put(opts(), :metadata, %{})
      {:ok, thread2} = EctoStorage.append_thread(thread_id, [%{kind: :note}], clear_opts)
      assert thread2.metadata == %{}
    end
  end

  # ===========================================================================
  # delete_thread transaction error handling (Issue #8/#18)
  # ===========================================================================

  describe "delete_thread error handling" do
    test "delete_thread raises when repo is invalid" do
      assert_raise UndefinedFunctionError, fn ->
        EctoStorage.delete_thread("some-thread", repo: NonExistentRepo)
      end
    end
  end

  # ===========================================================================
  # Binary format with prefix isolation (Issue #20)
  # ===========================================================================

  describe "binary format with prefix isolation" do
    test "checkpoints are isolated by prefix in binary format" do
      key = {TestAgent, "bin-prefix-#{System.unique_integer([:positive])}"}
      public_opts = opts(format: :binary)
      prefixed_opts = opts(format: :binary, prefix: "jido_test_prefix")

      :ok = EctoStorage.put_checkpoint(key, %{location: :public}, public_opts)
      :ok = EctoStorage.put_checkpoint(key, %{location: :prefixed}, prefixed_opts)

      {:ok, pub} = EctoStorage.get_checkpoint(key, public_opts)
      {:ok, pre} = EctoStorage.get_checkpoint(key, prefixed_opts)

      assert pub.location == :public
      assert pre.location == :prefixed
    end

    test "threads are isolated by prefix in binary format" do
      thread_id = "bin-prefix-thread-#{System.unique_integer([:positive])}"
      public_opts = opts(format: :binary)
      prefixed_opts = opts(format: :binary, prefix: "jido_test_prefix")

      {:ok, _} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note, payload: %{from: :public}}],
          public_opts
        )

      {:ok, _} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note, payload: %{from: :prefixed}}],
          prefixed_opts
        )

      {:ok, pub} = EctoStorage.load_thread(thread_id, public_opts)
      {:ok, pre} = EctoStorage.load_thread(thread_id, prefixed_opts)

      assert length(pub.entries) == 1
      assert length(pre.entries) == 1
      assert hd(pub.entries).payload.from == :public
      assert hd(pre.entries).payload.from == :prefixed
    end
  end

  # ===========================================================================
  # expected_rev edge cases (Issue #22)
  # ===========================================================================

  describe "expected_rev edge cases" do
    test "expected_rev: 0 succeeds on a new thread" do
      thread_id = "rev0-new-#{System.unique_integer([:positive])}"

      {:ok, thread} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note}],
          Keyword.put(opts(), :expected_rev, 0)
        )

      assert thread.rev == 1
    end

    test "expected_rev: 0 fails on an existing thread" do
      thread_id = "rev0-existing-#{System.unique_integer([:positive])}"
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note}], opts())

      assert {:error, :conflict} =
               EctoStorage.append_thread(
                 thread_id,
                 [%{kind: :note}],
                 Keyword.put(opts(), :expected_rev, 0)
               )
    end
  end

  # ===========================================================================
  # Concurrent delete + append (Issue #26)
  # ===========================================================================

  describe "concurrent delete and append" do
    test "delete_thread and append_thread serialize correctly" do
      thread_id = "concurrent-delete-#{System.unique_integer([:positive])}"
      parent = self()

      # Seed the thread
      {:ok, _} = EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 0}}], opts())

      # Run delete and append concurrently
      tasks =
        [
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(JidoStorageEcto.TestRepo, parent, self())
            EctoStorage.delete_thread(thread_id, opts())
          end),
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(JidoStorageEcto.TestRepo, parent, self())
            EctoStorage.append_thread(thread_id, [%{kind: :note, payload: %{n: 1}}], opts())
          end)
        ]

      results = Task.await_many(tasks, 10_000)

      # Both should complete without crashing. The append may return :not_found
      # if the delete's transaction commits between the append's write transaction
      # and its subsequent load_thread reload.
      assert Enum.all?(results, fn
               :ok -> true
               {:ok, _} -> true
               :not_found -> true
               _ -> false
             end)

      # Final state: either the thread exists (append won the race) or not (delete won)
      case EctoStorage.load_thread(thread_id, opts()) do
        {:ok, thread} ->
          # Append happened after delete — thread has entries
          assert length(thread.entries) >= 1

        :not_found ->
          # Delete happened after append — thread is gone
          :ok
      end
    end
  end

  # ===========================================================================
  # Struct handling in JSON format (Issue #13)
  # ===========================================================================

  describe "struct handling in json format" do
    test "structs are converted to plain maps without __struct__ key" do
      key = {TestAgent, "struct-test-#{System.unique_integer([:positive])}"}

      # Use a well-known struct
      uri = URI.parse("https://example.com/path")
      data = %{uri: uri, name: "test"}

      assert :ok = EctoStorage.put_checkpoint(key, data, opts())
      assert {:ok, retrieved} = EctoStorage.get_checkpoint(key, opts())

      # The struct should be a plain map without __struct__
      refute Map.has_key?(retrieved[:uri], :__struct__)
      refute Map.has_key?(retrieved[:uri], "__struct__")
      assert retrieved[:uri][:host] == "example.com"
      assert retrieved[:uri][:path] == "/path"
    end
  end

  # ===========================================================================
  # migrated_version (Issue #11)
  # ===========================================================================

  describe "Migration.migrated_version/1" do
    test "returns current version after up migration" do
      assert Jido.Storage.Ecto.Migration.migrated_version(repo: @repo) >= 1
    end

    test "returns version for prefixed schema" do
      assert Jido.Storage.Ecto.Migration.migrated_version(repo: @repo, prefix: "jido_test_prefix") >=
               1
    end
  end

  # ===========================================================================
  # Explicit format: :json (Issue #12)
  # ===========================================================================

  describe "explicit format: :json" do
    test "explicit format: :json works the same as default for checkpoints" do
      key = {TestAgent, "explicit-json-#{System.unique_integer([:positive])}"}
      json_opts = opts(format: :json)

      :ok = EctoStorage.put_checkpoint(key, %{val: 1}, json_opts)
      {:ok, data} = EctoStorage.get_checkpoint(key, json_opts)
      assert data[:val] == 1
    end

    test "explicit format: :json works the same as default for threads" do
      thread_id = "explicit-json-thread-#{System.unique_integer([:positive])}"
      json_opts = opts(format: :json)

      {:ok, thread} =
        EctoStorage.append_thread(
          thread_id,
          [%{kind: :note, payload: %{text: "hello"}}],
          json_opts
        )

      assert hd(thread.entries).payload[:text] == "hello"
    end
  end

  # ===========================================================================
  # Non-string thread_id (Issue #14)
  # ===========================================================================

  describe "non-string thread_id" do
    test "nil thread_id raises" do
      assert_raise ArgumentError, fn ->
        EctoStorage.append_thread(nil, [%{kind: :note}], opts())
      end
    end

    test "integer thread_id raises" do
      assert_raise Ecto.Query.CastError, fn ->
        EctoStorage.append_thread(123, [%{kind: :note}], opts())
      end
    end
  end

  # ===========================================================================
  # Format validation (Issue #9 from review 3)
  # ===========================================================================

  describe "format validation" do
    test "invalid format raises ArgumentError" do
      assert {:error, %ArgumentError{}} =
               EctoStorage.put_checkpoint(:k, %{}, opts(format: :msgpack))
    end

    test "string format raises ArgumentError" do
      assert {:error, %ArgumentError{}} =
               EctoStorage.put_checkpoint(:k, %{}, opts(format: "json"))
    end
  end

  # ===========================================================================
  # Cross-format reading (Issue #15 from review 3)
  # ===========================================================================

  describe "cross-format reading" do
    test "checkpoint written as binary can be read with json format (fallback)" do
      key = {:cross, "bin-to-json-#{System.unique_integer([:positive])}"}
      :ok = EctoStorage.put_checkpoint(key, %{val: 1}, opts(format: :binary))

      # Reading with :json format falls back to binary column
      {:ok, data} = EctoStorage.get_checkpoint(key, opts(format: :json))
      assert data.val == 1
    end

    test "checkpoint written as json can be read with binary format (fallback)" do
      key = {:cross, "json-to-bin-#{System.unique_integer([:positive])}"}
      :ok = EctoStorage.put_checkpoint(key, %{val: 1}, opts(format: :json))

      # Reading with :binary format falls back to json column
      {:ok, data} = EctoStorage.get_checkpoint(key, opts(format: :binary))
      assert data[:val] == 1
    end
  end

  # ===========================================================================
  # Error paths for delete operations (Issue #16 from review 3)
  # ===========================================================================

  describe "delete error paths" do
    test "delete_checkpoint raises when repo is invalid" do
      assert_raise UndefinedFunctionError, fn ->
        EctoStorage.delete_checkpoint(:k, repo: NonExistentRepo)
      end
    end
  end

  # ===========================================================================
  # Storage.normalize_storage/1
  # ===========================================================================

  describe "normalize_storage/1" do
    test "module atom normalizes to {Module, []}" do
      assert {Jido.Storage.Ecto, []} = Storage.normalize_storage(Jido.Storage.Ecto)
    end

    test "tuple passes through unchanged" do
      assert {Jido.Storage.Ecto, [repo: MyRepo]} =
               Storage.normalize_storage({Jido.Storage.Ecto, repo: MyRepo})
    end
  end
end
