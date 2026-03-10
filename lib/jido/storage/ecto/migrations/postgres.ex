defmodule Jido.Storage.Ecto.Migrations.Postgres do
  @moduledoc false

  use Ecto.Migration

  @initial_version 1
  @current_version 1
  @default_prefix "public"

  def initial_version, do: @initial_version
  def current_version, do: @current_version

  def up(opts) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  def down(opts) do
    opts = with_defaults(opts, @initial_version)
    initial = migrated_version(opts)

    if initial >= opts.version do
      change(initial..opts.version//-1, :down, opts)
    end
  end

  def migrated_version(opts) do
    opts = with_defaults(opts, @initial_version)

    repo = Map.get_lazy(opts, :repo, fn -> repo() end)
    prefix = Map.fetch!(opts, :prefix)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'jido_storage_checkpoints'
    AND pg_namespace.nspname = $1
    """

    case repo.query(query, [prefix], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute(
      "COMMENT ON TABLE #{quote_identifier(prefix)}.jido_storage_checkpoints IS '#{version}'"
    )
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, quote_identifier(opts.prefix))
    |> Map.put_new(:create_schema, opts.prefix != @default_prefix)
  end

  # Properly quote a SQL identifier by doubling any embedded double quotes.
  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, ~s("), ~s(""))}")
  end
end
