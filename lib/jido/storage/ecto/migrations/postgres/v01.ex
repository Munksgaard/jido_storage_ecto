defmodule Jido.Storage.Ecto.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(%{create_schema: create?, prefix: prefix, quoted_prefix: quoted}) do
    if create?, do: execute("CREATE SCHEMA IF NOT EXISTS #{quoted}")

    # -- Checkpoints: key-value overwrite store for agent state snapshots --
    create_if_not_exists table(:jido_storage_checkpoints,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :key, :text, null: false, primary_key: true
      add :key_display, :text
      add :data, :map
      add :data_binary, :binary

      timestamps(type: :utc_datetime_usec)
    end

    # -- Thread entries: append-only journal with sequence ordering --
    create_if_not_exists table(:jido_storage_thread_entries, prefix: prefix) do
      add :thread_id, :text, null: false
      add :seq, :integer, null: false
      add :entry_id, :text
      add :kind, :text, null: false
      add :at, :bigint, null: false
      add :payload, :map, default: %{}
      add :payload_binary, :binary
      add :refs, :map, default: %{}
      add :refs_binary, :binary

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create_if_not_exists unique_index(
                           :jido_storage_thread_entries,
                           [:thread_id, :seq],
                           prefix: prefix
                         )

    create_if_not_exists index(
                           :jido_storage_thread_entries,
                           [:thread_id],
                           prefix: prefix
                         )

    # -- Thread metadata: per-thread revision tracking and metadata --
    create_if_not_exists table(:jido_storage_thread_meta,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :thread_id, :text, null: false, primary_key: true
      add :rev, :integer, null: false, default: 0
      add :metadata, :map, default: %{}
      add :metadata_binary, :binary
      add :created_at, :bigint, null: false
      add :updated_at, :bigint, null: false
    end
  end

  def down(%{prefix: prefix, create_schema: created_schema?, quoted_prefix: quoted}) do
    drop_if_exists table(:jido_storage_thread_meta, prefix: prefix)
    drop_if_exists table(:jido_storage_thread_entries, prefix: prefix)
    drop_if_exists table(:jido_storage_checkpoints, prefix: prefix)

    # Drop the schema if we created it (non-public prefix)
    if created_schema? and prefix != "public" do
      execute("DROP SCHEMA IF EXISTS #{quoted}")
    end
  end
end
