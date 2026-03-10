import Config

# Base config — works locally with peer auth (no username/password).
# CI sets PGUSER/PGPASSWORD env vars for the postgres service container.
db_config = [
  database: "jido_storage_ecto_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  log: false
]

db_config =
  case System.get_env("PGUSER") do
    nil -> db_config
    user -> Keyword.merge(db_config, username: user, password: System.get_env("PGPASSWORD", ""))
  end

config :jido_storage_ecto, JidoStorageEcto.TestRepo, db_config

config :jido_storage_ecto, ecto_repos: [JidoStorageEcto.TestRepo]
