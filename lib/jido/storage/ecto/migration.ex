defmodule Jido.Storage.Ecto.Migration do
  @moduledoc """
  Migrations create and modify the database tables Jido Storage needs to function.

  ## Usage

  Generate an Ecto migration and call the `up` and `down` functions:

      mix ecto.gen.migration add_jido_storage

  ```elixir
  defmodule MyApp.Repo.Migrations.AddJidoStorage do
    use Ecto.Migration

    def up, do: Jido.Storage.Ecto.Migration.up()
    def down, do: Jido.Storage.Ecto.Migration.down()
  end
  ```

  Then run the migration:

      mix ecto.migrate

  ## Isolation with Prefixes

  Jido Storage supports namespacing through PostgreSQL schemas (called "prefixes"
  in Ecto). With prefixes, your storage tables can reside outside of the default
  `public` schema.

  ```elixir
  defmodule MyApp.Repo.Migrations.AddJidoStorage do
    use Ecto.Migration

    def up, do: Jido.Storage.Ecto.Migration.up(prefix: "jido")
    def down, do: Jido.Storage.Ecto.Migration.down(prefix: "jido")
  end
  ```

  The migration will create the `"jido"` schema and all tables within it. Then
  configure the adapter to use the same prefix:

      storage: {Jido.Storage.Ecto, repo: MyApp.Repo, prefix: "jido"}

  If the schema already exists, pass `create_schema: false`:

      Jido.Storage.Ecto.Migration.up(prefix: "jido", create_schema: false)

  ## Versioned Migrations

  Migrations are versioned and idempotent. As new versions are released, generate
  a new migration and specify the target version:

      mix ecto.gen.migration upgrade_jido_storage_to_v2

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradeJidoStorageToV2 do
    use Ecto.Migration

    def up, do: Jido.Storage.Ecto.Migration.up(version: 2)
    def down, do: Jido.Storage.Ecto.Migration.down(version: 2)
  end
  ```

  ## Options

  - `:prefix` - PostgreSQL schema name (default: `"public"`)
  - `:version` - Target migration version (default: latest for up, 1 for down)
  - `:create_schema` - Whether to create the PostgreSQL schema (default: `true`
    when prefix is not `"public"`)
  """

  use Ecto.Migration

  @doc """
  Run the `up` changes for all migrations up to the target version.

  ## Examples

      Jido.Storage.Ecto.Migration.up()
      Jido.Storage.Ecto.Migration.up(version: 1)
      Jido.Storage.Ecto.Migration.up(prefix: "jido")
      Jido.Storage.Ecto.Migration.up(prefix: "jido", create_schema: false)
  """
  def up(opts \\ []) when is_list(opts) do
    Jido.Storage.Ecto.Migrations.Postgres.up(opts)
  end

  @doc """
  Run the `down` changes, rolling back from the current version through
  the target version (inclusive). After rollback, the effective version
  is `target - 1`.

  ## Examples

      # Roll back all versions (default: version 1), leaving no tables
      Jido.Storage.Ecto.Migration.down()

      # Roll back only version 2, leaving version 1 intact
      Jido.Storage.Ecto.Migration.down(version: 2)

      Jido.Storage.Ecto.Migration.down(prefix: "jido")
  """
  def down(opts \\ []) when is_list(opts) do
    Jido.Storage.Ecto.Migrations.Postgres.down(opts)
  end

  @doc """
  Returns the latest migrated version for the given prefix.
  """
  def migrated_version(opts \\ []) when is_list(opts) do
    Jido.Storage.Ecto.Migrations.Postgres.migrated_version(opts)
  end
end
