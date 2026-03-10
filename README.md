# Jido Storage Ecto

[![Hex.pm](https://img.shields.io/hexpm/v/jido_storage_ecto.svg)](https://hex.pm/packages/jido_storage_ecto)

PostgreSQL storage adapter for [Jido](https://github.com/agentjido/jido) agent
checkpoints and thread journals. Provides durable, ACID-compliant persistence
that survives restarts and deployments.

## Installation

Add `jido_storage_ecto` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_storage_ecto, "~> 0.1.0"}
  ]
end
```

## Setup

### 1. Generate a migration

```bash
mix ecto.gen.migration add_jido_storage
```

```elixir
defmodule MyApp.Repo.Migrations.AddJidoStorage do
  use Ecto.Migration

  def up, do: Jido.Storage.Ecto.Migration.up()
  def down, do: Jido.Storage.Ecto.Migration.down()
end
```

```bash
mix ecto.migrate
```

### 2. Configure your Jido instance

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    storage: {Jido.Storage.Ecto, repo: MyApp.Repo}
end
```

That's it. `hibernate/1`, `thaw/2`, and `InstanceManager` all work automatically.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `:repo` | (required) | Your `Ecto.Repo` module |
| `:prefix` | `"public"` | PostgreSQL schema for table isolation |
| `:format` | `:json` | `:json` (queryable, human-readable) or `:binary` (lossless) |

## Data Formats

### JSON (default)

Stores data as `jsonb`. Queryable and human-readable in the database.

**Trade-off:** Atom keys are restored on read via `String.to_existing_atom/1`
(safe). Atom *values* become strings — handle this in your `restore/2` callback.

```elixir
storage: {Jido.Storage.Ecto, repo: MyApp.Repo, format: :json}
```

### Binary

Stores data via `:erlang.term_to_binary` as `bytea`. Lossless round-trip —
atoms, tuples, and structs are preserved exactly. Decoded with the `[:safe]`
flag to prevent atom table exhaustion.

```elixir
storage: {Jido.Storage.Ecto, repo: MyApp.Repo, format: :binary}
```

## PostgreSQL Schema Isolation

For multi-tenant or namespaced deployments, use the `:prefix` option. This maps
to a PostgreSQL schema.

```elixir
# Migration
def up, do: Jido.Storage.Ecto.Migration.up(prefix: "tenant_1")
def down, do: Jido.Storage.Ecto.Migration.down(prefix: "tenant_1")

# Configuration
storage: {Jido.Storage.Ecto, repo: MyApp.Repo, prefix: "tenant_1"}
```

## Tables

The migration creates three tables (within your configured prefix/schema):

| Table | Purpose |
|-------|---------|
| `jido_storage_checkpoints` | Key-value store for agent state snapshots |
| `jido_storage_thread_entries` | Append-only journal for thread entries |
| `jido_storage_thread_meta` | Per-thread revision tracking and metadata |

## Versioned Migrations

Migrations are versioned (like Oban). As new versions are released, generate a
new Ecto migration:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeJidoStorageToV2 do
  use Ecto.Migration

  def up, do: Jido.Storage.Ecto.Migration.up(version: 2)
  def down, do: Jido.Storage.Ecto.Migration.down(version: 2)
end
```

## License

Apache-2.0
