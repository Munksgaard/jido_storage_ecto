defmodule Jido.Storage.Ecto.ThreadMeta do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:thread_id, :string, autogenerate: false}

  schema "jido_storage_thread_meta" do
    field :rev, :integer, default: 0
    field :metadata, :map
    field :metadata_binary, :binary
    # Stored as :bigint in PostgreSQL (millisecond timestamps exceed int32 range).
    # Ecto's :integer type handles arbitrary-precision Elixir integers on read/write.
    field :created_at, :integer
    field :updated_at, :integer
  end
end
