defmodule Jido.Storage.Ecto.ThreadEntry do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "jido_storage_thread_entries" do
    field :thread_id, :string
    field :seq, :integer
    field :entry_id, :string
    field :kind, :string
    field :at, :integer
    field :payload, :map
    field :payload_binary, :binary
    field :refs, :map
    field :refs_binary, :binary

    timestamps(updated_at: false)
  end
end
