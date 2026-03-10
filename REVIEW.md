# Code Review: jido_storage_ecto

**Reviewed**: 2026-03-10  
**Files reviewed**: All source under `lib/`, `test/`, `config/`, `mix.exs`, plus
`Jido.Storage` behaviour, `Jido.Storage.ETS`, `Jido.Storage.File` for comparison.

---

## Summary

Solid first iteration. The adapter correctly implements all 6 callbacks of the
`Jido.Storage` behaviour, uses advisory locks for safe concurrent appends, and
has a clean migration system. The dual JSON/binary encoding design is
thoughtful. There are several issues ranging from a genuine data-integrity bug
to missing test coverage and minor inconsistencies with the other adapters.

---

## 1. Correctness Against Jido.Storage Behaviour

### 1.1 ✅ All 6 callbacks implemented

`get_checkpoint`, `put_checkpoint`, `delete_checkpoint`, `load_thread`,
`append_thread`, `delete_thread` — all present with `@impl true`.

### 1.2 ✅ Return types match the behaviour spec

- `get_checkpoint` → `{:ok, data} | :not_found | {:error, e}`
- `put_checkpoint` → `:ok | {:error, e}`
- `delete_checkpoint` → `:ok` (idempotent, matches behaviour)
- `load_thread` → `{:ok, Thread.t()} | :not_found | {:error, e}`
- `append_thread` → `{:ok, Thread.t()} | {:error, :conflict} | {:error, e}`
- `delete_thread` → `:ok` (idempotent)

### 1.3 ✅ `expected_rev` / conflict detection works

Advisory lock + `validate_expected_rev` inside the transaction. The concurrent
test verifies only one writer succeeds when two race with the same
`expected_rev`.

### 1.4 ⚠️ `rev` inconsistency between meta and reconstructed thread

`reconstruct_thread/3` sets `rev: entry_count` (= `length(entries)`), but the
optimistic concurrency check in `append_thread` reads `current_rev` from
`meta.rev`. Under normal operation these are identical, but they are derived
from different sources. If they ever diverge (partial failure, manual DB edit,
migration bug), a client doing:

```elixir
{:ok, thread} = append_thread(id, entries, opts)
append_thread(id, more, expected_rev: thread.rev)  # uses entry_count
# but the check compares against meta.rev
```

will get a surprising `:conflict` or silent success. The **File adapter** uses
`rev: new_rev` (from meta), which is more correct. The **ETS adapter** has the
same `rev: entry_count` pattern as this adapter.

**Recommendation**: Use `meta.rev` instead of `entry_count` in
`reconstruct_thread`, like the File adapter does:

```elixir
rev: if(meta, do: meta.rev, else: entry_count),
```

---

## 2. Bugs and Edge Cases

### 2.1 🐛 `encode_entry_payload` used for refs encoding (naming confusion)

In `insert_entries/5`:

```elixir
{refs_json, refs_binary} = encode_entry_payload(entry.refs, format)
```

This calls `encode_entry_payload` for refs. It works (the function is generic),
but there's a dedicated decode path `decode_entry_refs` on the read side. The
asymmetry is confusing and could lead to bugs if `encode_entry_payload` is
later changed to do payload-specific logic. Consider renaming to a shared
`encode_value/2` + `decode_value/3` pair, or adding an `encode_entry_refs/2`
alias.

### 2.2 🐛 Appending an empty entries list creates/updates meta without adding entries

If you call `append_thread(id, [], opts)`, the code will:
1. Normalize an empty list → `prepared = []`
2. `insert_entries` with `[]` → short-circuits via the `[] ->` clause (fine)
3. `new_rev = current_rev + 0` → no rev change
4. `upsert_meta` still runs — on a new thread this creates a meta row with
   `rev: 0` but zero entries
5. The subsequent `load_thread` finds no entries → returns `:not_found`
6. But the meta row exists as an orphan

Both ETS and File adapters have similar behaviour, so this is consistent but
still a leak. Consider returning `{:error, :empty_entries}` or short-circuiting
when `entries == []`.

### 2.3 ⚠️ `put_checkpoint` swallows the `repo.insert` return value

```elixir
repo.insert(struct(Checkpoint, attrs), ...)
:ok
```

The result of `repo.insert/2` is discarded. If it returns `{:error, changeset}`,
the function still returns `:ok`. This could mask constraint violations or DB
errors that aren't exceptions. Should be:

```elixir
case repo.insert(struct(Checkpoint, attrs), ...) do
  {:ok, _} -> :ok
  {:error, changeset} -> {:error, changeset}
end
```

### 2.4 ⚠️ `upsert_meta` uses `repo.insert!` (raises on error)

In the `is_new == true` branch, `repo.insert!` is used. If the upsert fails
(e.g., `on_conflict` clause can't handle the case), it raises an exception that
gets caught by the outer `rescue e -> {:error, e}`. This works, but
`repo.insert` (non-bang) would be more intentional.

### 2.5 ⚠️ `async: true` on a test module that uses `pg_advisory_xact_lock`

The test module declares `use JidoStorageEcto.DataCase, async: true`. Advisory
locks are connection-level PostgreSQL features. In Sandbox mode with
`shared: not tags[:async]` (i.e. `shared: false` when `async: true`), each test
gets its own connection, so advisory locks should work. However, the concurrent
tests use `Sandbox.allow` to share the parent's sandbox with spawned tasks.
Since `async: true` means non-shared sandbox, the advisory lock behaviour could
be subtly different from production (locks scoped per-sandbox-connection vs
per-real-connection). This seems to work in practice but is worth a comment.

### 2.6 ⚠️ `phash2` collision risk for advisory locks

`phash2` returns values in `0..2^27-1`, giving ~134M buckets. Two different
`{prefix, thread_id}` pairs could hash to the same value, causing unnecessary
serialization. This is unlikely in practice but worth documenting. An
alternative is to use a single-argument `pg_advisory_xact_lock(bigint)` with a
better hash.

### 2.7 ⚠️ No handling of `Postgrex.Error` specifically

All callbacks use a blanket `rescue e -> {:error, e}`. This catches everything,
but the caller has no way to distinguish a connection error from a constraint
violation from a serialization bug. Consider at minimum matching on
`Postgrex.Error` and `Ecto.StaleEntryError`.

---

## 3. Migration Review

### 3.1 ✅ Well-structured versioned migration system

The `Migration` → `Migrations.Postgres` → `V01` layering is clean and
follows established patterns (similar to Oban). Version tracking via
`COMMENT ON TABLE` is clever.

### 3.2 ✅ `create_if_not_exists` for idempotency

Good — re-running the migration won't crash.

### 3.3 ⚠️ `down` migration doesn't drop schema

If `up` created the schema with `CREATE SCHEMA IF NOT EXISTS`, `down` should
optionally drop it. Currently it only drops tables.

### 3.4 ⚠️ `:text` in migration vs `:string` in Ecto schemas

The migration uses `:text` for all string columns (`key`, `thread_id`,
`entry_id`, `kind`, `key_display`), but the Ecto schemas use `field :key,
:string`. In PostgreSQL, `text` and `varchar` (which Ecto's `:string` maps to)
are equivalent, so this works fine. But it's a stylistic inconsistency — using
`:string` in both places (or `:text` in both) would be cleaner.

### 3.5 ⚠️ Missing index on `thread_entries.entry_id`

If you ever need to look up an entry by its logical ID (not just by
`thread_id + seq`), there's no index on `entry_id`. May be worth adding
depending on future query patterns.

### 3.6 ✅ Unique index on `(thread_id, seq)` is correct

This enforces the append-only invariant at the DB level.

---

## 4. Test Coverage Gaps

### 4.1 ✅ Good coverage of happy paths

29 tests covering checkpoints CRUD, thread CRUD, JSON/binary formats,
concurrency, `expected_rev`, seq numbering, timestamps, metadata.

### 4.2 ❌ No test for appending empty entries `[]`

This triggers the edge case described in §2.2.

### 4.3 ❌ No test for `:prefix` option

The prefix/schema isolation feature is documented and implemented but
completely untested.

### 4.4 ❌ No test for missing `:repo` option

`repo!/1` raises `ArgumentError`, but there's no test confirming this.

### 4.5 ❌ No test for `load_thread` after multiple appends with `load_thread`

There's `"returns correct Thread with all entries"` but it only does a single
`append_thread` followed by `load_thread`. No test verifies load after
*multiple sequential appends* (the `"appends to existing thread"` test checks
the return of `append_thread`, not `load_thread`).

### 4.6 ❌ No test for binary format `load_thread` round-trip

The binary format tests check `append_thread` return values and do a
`load_thread`, but don't verify that refs survive the round-trip (only
payload is tested).

### 4.7 ❌ No error-path tests

No tests for:
- Database connection failures
- Constraint violations
- Invalid data that can't be JSON-encoded (e.g., PID values in JSON mode)

### 4.8 ❌ No test for `delete_thread` actually cleaning up meta row

The test checks that `load_thread` returns `:not_found` after delete, but
doesn't verify the meta row is also removed (could be verified with a raw
query or by attempting an append that would conflict).

### 4.9 ❌ Missing `LICENSE` file

`mix.exs` package config references `LICENSE` but the file doesn't exist.

---

## 5. Code Quality & Idiomatic Elixir/Ecto

### 5.1 ✅ Clean module structure

Good separation: adapter logic in `ecto.ex`, schemas in separate files,
migrations in their own namespace.

### 5.2 ✅ Dual JSON/binary encoding is well thought out

The fallback chain in decode functions (preferred format → whatever has data)
is a nice touch for format migration scenarios.

### 5.3 ⚠️ Using `struct/2` instead of changesets

Throughout the adapter, Ecto records are built with `struct(Checkpoint, attrs)`
rather than changesets. This bypasses Ecto validations and casting. For an
internal adapter this is acceptable, but it means:
- No validation errors — just DB constraint errors
- Timestamps must be set manually
- Fields must exactly match the schema types

This is a deliberate trade-off (performance, simplicity) but worth
documenting.

### 5.4 ⚠️ `safe_to_existing_atom` for `kind` field

`record_to_entry` converts `kind` back to an atom via
`safe_to_existing_atom(record.kind)`. This is safe (won't create atoms) but
means if the atom doesn't exist in the current VM (e.g., a custom kind used by
a different node), it will remain a string. This is documented for JSON values
but not for the `kind` field specifically, which is always stored as a string.

### 5.5 ✅ Advisory lock usage is correct

Using `pg_advisory_xact_lock` (transaction-scoped, auto-released) is the
right choice. The lock is acquired before reading state, preventing TOCTOU.

### 5.6 Minor style notes

- `case is_new do true -> ... false -> ...` — could be a simpler
  `if is_new do ... else ... end`
- The `rescue e ->` blocks could be more specific
- Some private functions are long (e.g., `append_thread` at ~30 lines inside
  the transaction)

---

## 6. Consistency with ETS and File Adapters

| Feature | ETS | File | Ecto |
|---------|-----|------|------|
| `rev` source in reconstructed thread | `entry_count` | `meta.rev` | `entry_count` ⚠️ |
| Concurrency mechanism | `:global.trans` | `:global.trans` | `pg_advisory_xact_lock` ✅ |
| `expected_rev` check | ✅ | ✅ | ✅ |
| Metadata on first append | ✅ | ✅ | ✅ |
| Metadata update on subsequent appends | `updated_at` only | `updated_at` only | `rev` + `updated_at` ✅ |
| `delete_thread` idempotent | ✅ | ✅ | ✅ |
| `delete_checkpoint` idempotent | ✅ | ✅ | ✅ |
| Thread `created_at`/`updated_at` type | ms integer | ms integer | ms integer ✅ |
| Entry `at` type | ms integer | ms integer | ms integer ✅ |

The main inconsistency is `rev` sourcing (§1.4). Otherwise the adapter is
well-aligned with the ETS and File adapters in semantics and return types.

---

## Priority Summary

| # | Severity | Issue |
|---|----------|-------|
| 2.3 | **High** | `put_checkpoint` silently swallows insert errors |
| 1.4 | **Medium** | `rev: entry_count` vs `meta.rev` inconsistency |
| 2.2 | **Medium** | Empty entries list creates orphan meta row |
| 4.3 | **Medium** | No tests for `:prefix` feature |
| 4.7 | **Medium** | No error-path tests |
| 2.1 | **Low** | `encode_entry_payload` naming confusion for refs |
| 2.4 | **Low** | `repo.insert!` in `upsert_meta` |
| 3.3 | **Low** | `down` migration doesn't drop schema |
| 3.4 | **Low** | `:text` vs `:string` inconsistency |
| 4.9 | **Low** | Missing `LICENSE` file |
