alias JidoStorageEcto.TestRepo

# Start the repo
{:ok, _} = TestRepo.start_link()

# Run our V1 migration in public schema (idempotent)
defmodule JidoStorageEcto.TestMigration do
  use Ecto.Migration
  def up, do: Jido.Storage.Ecto.Migration.up()
  def down, do: Jido.Storage.Ecto.Migration.down()
end

# Migration for prefix isolation tests
defmodule JidoStorageEcto.PrefixTestMigration do
  use Ecto.Migration

  def up do
    Jido.Storage.Ecto.Migration.up(prefix: "jido_test_prefix")
  end

  def down do
    Jido.Storage.Ecto.Migration.down(prefix: "jido_test_prefix")
  end
end

Ecto.Migrator.up(TestRepo, 1, JidoStorageEcto.TestMigration, log: false)
Ecto.Migrator.up(TestRepo, 2, JidoStorageEcto.PrefixTestMigration, log: false)

# Set sandbox mode
Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

ExUnit.start()
