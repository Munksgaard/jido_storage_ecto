defmodule Jido.Storage.Ecto.Checkpoint do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "jido_storage_checkpoints" do
    field :key_display, :string
    field :data, :map
    field :data_binary, :binary

    timestamps()
  end
end
