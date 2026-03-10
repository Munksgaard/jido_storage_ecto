defmodule JidoStorageEcto.TestRepo do
  use Ecto.Repo,
    otp_app: :jido_storage_ecto,
    adapter: Ecto.Adapters.Postgres
end
