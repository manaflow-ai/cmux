import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applyPendingMigrations, readNoTransactionMigrations } from "../scripts/cloud-vm/apply-migrations.mjs";

// B2 of leo-workspace notes/web-next-to-cmux-com.md: next's Run migrations plus the run_model
// enums / expand / validate steps, applied through the runner production uses, onto the three
// starting shapes a database with main's ledger can have: none (CI), main's (production) and
// staging's hybrid (next's first three Run migrations, then main's four).
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
// Keeps the three migrated databases (cmux_run_model_<shape>) so other suites can run against them.
const keepDatabases = process.env.CMUX_RUN_MODEL_KEEP_DATABASES === "1";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { Pool } = requireFromWeb("pg");
type PgPool = InstanceType<typeof Pool>;

const realFolder = path.join(webDir, "db/migrations");
const noTransaction = readNoTransactionMigrations(path.join(webDir, "db/no-transaction-migrations.json"));

/** The folders B2 brings to main. A database with main's ledger has none of them. */
const fromNext = [
  "20261016000000_run_api", "20261017000000_runtime_persistence", "20261017010000_runtime_workspaces",
  "20261019120000_run_writer_lease", "20261023120000_gcp_vm_provider",
  "20261025120000_run_sandboxed_environment", "20261025120100_run_sandboxed_environment_validate",
];
const runModelSteps = ["20261028000000_run_model_enums", "20261028000100_run_model_expand", "20261028000200_run_model_validate"];
const addedByB2 = [...fromNext, ...runModelSteps];
const mainRunMigrations = [
  "20261017150000_run_api", "20261018000000_run_attempts_variant_repair",
  "20261018110000_durable_team_runs", "20261018120000_run_artifacts_schema_compat",
];
// Every added folder except runtime_workspaces (an unguarded CREATE TABLE that runs once) is safe to run twice.
const rerunnable = addedByB2.filter((name) => name !== "20261017010000_runtime_workspaces");

// next's schema.ts (feat-cmux-next 078271b5774) columns and enum labels for the tables B2 reconciles.
const nextColumns: Record<string, string[]> = {
  runs: ["id", "user_id", "billing_team_id", "idempotency_key", "request_digest", "source", "recipe", "provider", "desired_attempts", "environment", "image_id", "image_version", "receipt", "status", "cancel_requested_at", "completed_at", "error", "created_at", "updated_at"],
  run_attempts: ["id", "run_id", "runtime_id", "ordinal", "status", "provider_vm_id", "provider_workspace_id", "provider_terminal_id", "terminal_retain_until", "attach_ticket_hash", "attach_ticket_expires_at", "attach_ticket_consumed_at", "cleanup_lease_token", "cleanup_lease_expires_at", "lease_token", "lease_generation", "lease_expires_at", "source_digest", "result", "exit_code", "error", "started_at", "finished_at", "created_at", "updated_at"],
  run_events: ["id", "run_id", "attempt_id", "sequence", "attempt_sequence", "external_id", "kind", "payload", "writer_lease_generation", "writer_lease_token_hash", "created_at"],
  run_artifacts: ["id", "run_id", "attempt_id", "name", "media_type", "size_bytes", "digest", "uri", "metadata", "writer_lease_generation", "writer_lease_token_hash", "created_at"],
  cloud_runtimes: ["id", "owner_team_id", "runtime_kind", "lifecycle_state", "journal_session_id", "machine_id", "placement_generation", "lease_token", "lease_generation", "lease_expires_at", "idempotency_key", "created_at", "updated_at", "released_at"],
  cloud_runtime_workspaces: ["runtime_id", "owner_team_id", "workspace_id", "workspace_name", "provider", "lifecycle", "provider_vm_id", "provider_workspace_id", "provider_terminal_id", "owner_id", "idempotency_key", "request_digest", "failure_code", "failure_message", "version", "created_at", "updated_at"],
};
const nextEnums: Record<string, string[]> = {
  run_status: ["queued", "running", "cancelling", "succeeded", "failed", "cancelled"],
  run_attempt_status: ["queued", "leased", "running", "succeeded", "failed", "cancelled", "expired"],
  run_event_kind: ["run.created", "attempt.queued", "attempt.started", "attempt.heartbeat", "attempt.output", "attempt.artifact", "attempt.succeeded", "attempt.failed", "run.cancel_requested", "run.completed"],
  vm_provider: ["freestyle", "gcp"],
  cloud_runtime_kind: ["persistent", "ephemeral"],
  cloud_runtime_lifecycle: ["provisioning", "ready", "running", "draining", "suspended", "stopped", "released", "failed"],
};
const rowTables = ["runs", "run_attempts", "run_events", "run_artifacts", "run_attach_tickets", "cloud_runtimes"];

const scratchRoot = mkdtempSync(path.join(tmpdir(), "cmux-run-model-migrations-"));
let folderCount = 0;
/** A copy of the real folder holding only the migrations `keep` accepts, with the real no-transaction list cut to match. */
function folder(keep: (name: string) => boolean) {
  const root = path.join(scratchRoot, `folder-${++folderCount}`);
  for (const name of readdirSync(realFolder).filter(keep)) cpSync(path.join(realFolder, name), path.join(root, name), { recursive: true });
  const noTransactionManifest = `${root}.no-transaction-migrations.json`;
  writeFileSync(noTransactionManifest, JSON.stringify({ migrations: [...noTransaction].filter(keep) }));
  return { migrationsFolder: root, noTransactionManifest };
}

let adminPool: PgPool | null = null;
const databasePools: Array<{ name: string; pool: PgPool }> = [];

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  adminPool = new Pool({ connectionString: databaseURL, max: 1 });
});

afterAll(async () => {
  for (const { name, pool } of databasePools) {
    await pool.end();
    if (!keepDatabases) await adminPool?.query(`drop database if exists "${name}" with (force)`);
  }
  await adminPool?.end();
  rmSync(scratchRoot, { recursive: true, force: true });
});

async function freshDatabase(shape: string): Promise<PgPool> {
  if (!adminPool) throw new Error("CMUX_DB_TEST=1 is required");
  const name = keepDatabases ? `cmux_run_model_${shape}` : `cmux_run_model_${process.pid}_${shape}`;
  await adminPool.query(`drop database if exists "${name}" with (force)`);
  await adminPool.query(`create database "${name}"`);
  const url = new URL(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? "");
  url.pathname = `/${name}`;
  const pool = new Pool({ connectionString: url.href, max: 1 });
  databasePools.push({ name, pool });
  return pool;
}

const applyRealFolder = (pool: PgPool) => applyPendingMigrations(pool, webDir);
const rows = async (pool: PgPool, sql: string, params: unknown[] = []): Promise<Array<Record<string, any>>> => (await pool.query(sql, params)).rows;

/** Every row of the Run tables, keyed by table and primary key. */
async function snapshotRows(pool: PgPool) {
  const snapshot: Record<string, Record<string, Record<string, unknown>>> = {};
  for (const table of rowTables) {
    snapshot[table] = {};
    for (const { row } of await rows(pool, `select to_jsonb(t) as row from "${table}" t`)) snapshot[table][row.id ?? row.digest] = row;
  }
  return snapshot;
}

/** Every row from `before` is still there with the same values in the columns it had. Columns the migrations add are checked by the cases themselves. */
function expectRowsKept(before: Awaited<ReturnType<typeof snapshotRows>>, after: Awaited<ReturnType<typeof snapshotRows>>) {
  for (const table of rowTables) {
    expect(Object.keys(after[table]).sort()).toEqual(Object.keys(before[table]).sort());
    for (const [key, row] of Object.entries(before[table])) {
      const kept = Object.fromEntries(Object.keys(row).map((column) => [column, after[table][key][column]]));
      expect({ table, key, row: kept }).toEqual({ table, key, row });
    }
  }
}

/** Columns and enum labels next's schema.ts declares that the database lacks. */
async function missingFromNext(pool: PgPool) {
  const missing: Record<string, string[]> = {};
  for (const [table, expected] of Object.entries(nextColumns)) {
    const present = new Set((await rows(pool, "select column_name from information_schema.columns where table_schema = 'public' and table_name = $1", [table])).map((row) => row.column_name));
    missing[table] = expected.filter((column) => !present.has(column));
  }
  for (const [type, expected] of Object.entries(nextEnums)) {
    const present = new Set((await rows(pool, "select e.enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = $1", [type])).map((row) => row.enumlabel));
    missing[type] = expected.filter((label) => !present.has(label));
  }
  return Object.fromEntries(Object.entries(missing).filter(([, names]) => names.length > 0));
}

/** The Run tables' catalog, keyed by object, in a form two databases can be compared by. */
async function catalog(pool: PgPool) {
  const tables = [...Object.keys(nextColumns), "run_attach_tickets"];
  const entries = [
    ...(await rows(pool, `select table_name || '.' || column_name as key, concat_ws(' ', udt_name, is_nullable, column_default) as def
      from information_schema.columns where table_schema = 'public' and table_name = any($1)`, [tables])),
    ...(await rows(pool, `select 'constraint ' || conname as key, concat_ws(' ', convalidated, pg_get_constraintdef(oid)) as def
      from pg_constraint where connamespace = 'public'::regnamespace and conrelid::regclass::text = any($1)`, [tables])),
    ...(await rows(pool, "select 'index ' || indexname as key, indexdef as def from pg_indexes where schemaname = 'public' and tablename = any($1)", [tables])),
    ...(await rows(pool, `select 'enum ' || t.typname as key, array_agg(e.enumlabel order by e.enumlabel)::text as def
      from pg_type t join pg_enum e on e.enumtypid = t.oid where t.typname = any($1) group by t.typname`, [Object.keys(nextEnums)])),
  ];
  return Object.fromEntries(entries.map((entry) => [entry.key, entry.def])) as Record<string, string>;
}

/** Keys whose definitions differ between two catalogs (or exist in one only). */
function catalogDifferences(a: Record<string, string>, b: Record<string, string>) {
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].filter((key) => a[key] !== b[key]).sort();
}

async function expectReplayIsNoOp(pool: PgPool) {
  expect(await applyRealFolder(pool)).toBe(0);
  const before = await catalog(pool);
  const rowsBefore = await snapshotRows(pool);
  await pool.query("delete from drizzle.__drizzle_migrations where name = any($1)", [rerunnable]);
  expect(await applyRealFolder(pool)).toBe(rerunnable.length);
  expect(await catalog(pool)).toEqual(before);
  expect(await snapshotRows(pool)).toEqual(rowsBefore);
}

const ids = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const digest = (c: string) => `sha256:${c.repeat(64)}`;
const catalogs: Record<string, Record<string, string>> = {};

describe("Run model migrations on main's three starting shapes", () => {
  dbTest("an empty database gets next's Run schema, and a replay changes nothing", async () => {
    const pool = await freshDatabase("empty");
    expect(await applyRealFolder(pool)).toBeGreaterThan(addedByB2.length);
    expect(await missingFromNext(pool)).toEqual({});
    await expectReplayIsNoOp(pool);
    catalogs.empty = await catalog(pool);
  });

  dbTest("main's production shape, holding rows, migrates and keeps every row", async () => {
    const pool = await freshDatabase("main");
    expect(await applyPendingMigrations(pool, webDir, folder((name) => !addedByB2.includes(name)))).toBeGreaterThan(0);
    expect(await missingFromNext(pool)).not.toEqual({});
    await pool.query(`
      insert into cloud_runtimes (id, owner_team_id) values ('${ids(1)}', 'team-a');
      insert into runs (id, user_id, request_digest, source, recipe, owner_team_id, spec, idempotency_key, status)
        values ('${ids(10)}', 'user-a', 'd1', '{"repository":"r"}', 'recipe', 'team-a', '{"v":1}', 'k1', 'running'),
               ('${ids(11)}', 'user-a', 'd2', '{}', 'recipe', null, null, 'k1', 'cancelled');
      insert into run_attempts (id, run_id, ordinal, variant, status, lease_id, lease_until, worker_id, checkpoint, cleanup_state, retained_until, promoted_at, runtime_id, provider_vm_id)
        values ('${ids(20)}', '${ids(10)}', 0, '{"a":1}', 'running', '${ids(90)}', now(), 'worker', '{"step":2}', 'retained', now(), null, '${ids(99)}', 'vm-1'),
               ('${ids(21)}', '${ids(10)}', 1, '{}', 'succeeded', null, null, null, '{}', 'pending', null, now(), '${ids(1)}', 'vm-2'),
               ('${ids(22)}', '${ids(11)}', 0, '{}', 'cancelled', null, null, null, '{}', 'deleted', null, null, null, null);
      insert into run_events (id, run_id, attempt_id, sequence, kind, payload)
        values ('${ids(30)}', '${ids(10)}', null, 1, 'run.created', '{}'), ('${ids(31)}', '${ids(10)}', '${ids(20)}', 2, 'attempt.cancelled', '{"r":1}'),
               ('${ids(32)}', '${ids(11)}', null, 1, 'run.cancelled', '{}');
      insert into run_artifacts (id, run_id, attempt_id, name, digest, payload, size_bytes)
        values ('${ids(40)}', '${ids(10)}', '${ids(21)}', 'receipt', '${digest("a")}', '{"k":1}', 7);
      insert into run_attach_tickets (digest, run_id, attempt_id, owner_team_id, user_id, provider_vm_id, expires_at)
        values ('${digest("b")}', '${ids(10)}', '${ids(20)}', 'team-a', 'user-a', 'vm-1', now());
    `);
    const before = await snapshotRows(pool);

    expect(await applyRealFolder(pool)).toBe(addedByB2.length);
    const after = await snapshotRows(pool);
    // The one rewrite: the orphan runtime_id (main's column had no FK) becomes NULL before the FK is validated.
    expect(after.run_attempts[ids(20)].runtime_id).toBeNull();
    (before.run_attempts[ids(20)] as Record<string, unknown>).runtime_id = null;
    expectRowsKept(before, after);
    // Existing rows get the new columns' defaults.
    expect(await rows(pool, "select lease_generation from run_attempts")).toEqual([{ lease_generation: 0 }, { lease_generation: 0 }, { lease_generation: 0 }]);
    expect(await rows(pool, "select media_type, uri, metadata from run_artifacts")).toEqual([{ media_type: "application/json", uri: "inline://cmux-run-artifact", metadata: {} }]);
    expect(await rows(pool, "select environment from runs order by id")).toEqual([{ environment: "persistent" }, { environment: "persistent" }]);
    // runtime_persistence fills the cloud_runtimes columns it adds, once: a runtime with no machine is released at its creation time.
    expect(await rows(pool, "select lifecycle_state::text, released_at = created_at as released_at_created, lease_generation from cloud_runtimes"))
      .toEqual([{ lifecycle_state: "released", released_at_created: true, lease_generation: 0 }]);
    // main's inserts, which name none of next's columns, still pass.
    await pool.query(`insert into run_attempts (run_id, ordinal, variant) values ('${ids(11)}', 1, '{}');
      insert into run_artifacts (run_id, attempt_id, name, digest, payload, size_bytes) values ('${ids(11)}', '${ids(22)}', 'x', '${digest("c")}', '{}', 2)`);
    // next's inserts, which name none of main's columns and use next's enum values, pass too.
    await pool.query(`insert into run_attempts (run_id, ordinal, status, lease_token, lease_generation) values ('${ids(11)}', 2, 'leased', 't', 1);
      insert into run_artifacts (run_id, attempt_id, name, media_type, size_bytes, digest, uri) values ('${ids(11)}', '${ids(22)}', 'y', 'text/plain', 1, '${digest("f")}', 'r2://b/y');
      insert into run_events (run_id, sequence, kind, attempt_sequence, external_id) values ('${ids(11)}', 2, 'run.completed', null, 'e')`);
    await pool.query(`delete from run_events where run_id = '${ids(11)}' and sequence = 2;
      delete from run_artifacts where name in ('x', 'y'); delete from run_attempts where run_id = '${ids(11)}' and ordinal > 0`);

    expect(await missingFromNext(pool)).toEqual({});
    await expectReplayIsNoOp(pool);
    catalogs.main = await catalog(pool);
  });

  dbTest("a legacy artifact that breaks next's checks is kept, and those checks stay NOT VALID", async () => {
    const pool = await freshDatabase("legacy_artifact");
    await applyPendingMigrations(pool, webDir, folder((name) => !addedByB2.includes(name)));
    await pool.query(`
      insert into runs (id, user_id, request_digest, source, recipe) values ('${ids(10)}', 'user-a', 'd1', '{}', 'recipe');
      insert into run_attempts (id, run_id, ordinal, variant) values ('${ids(20)}', '${ids(10)}', 0, '{}');
      insert into run_artifacts (id, run_id, attempt_id, name, digest, payload, size_bytes)
        values ('${ids(40)}', '${ids(10)}', '${ids(20)}', 'legacy', 'sha256:x', '{}', 600000000);
    `);
    const before = await snapshotRows(pool);
    expect(await applyRealFolder(pool)).toBe(addedByB2.length);
    expectRowsKept(before, await snapshotRows(pool));
    expect(await rows(pool, `select conname, convalidated from pg_constraint where conrelid = 'run_artifacts'::regclass and contype = 'c' order by conname`))
      .toEqual([{ conname: "run_artifacts_digest_check", convalidated: false }, { conname: "run_artifacts_size_check", convalidated: false }]);
    // The checks still hold new writes.
    await expect(pool.query(`insert into run_artifacts (run_id, attempt_id, name, digest, payload, size_bytes) values ('${ids(10)}', '${ids(20)}', 'new', 'sha256:y', '{}', 1)`)).rejects.toThrow("run_artifacts_digest_check");
    expect(await applyRealFolder(pool)).toBe(0);
  });

  dbTest("staging's hybrid, holding rows from both models, migrates and keeps every row", async () => {
    const pool = await freshDatabase("hybrid");
    const nextFirst = new Set(fromNext.slice(0, 3));
    const isBefore = (name: string) => name < fromNext[0];
    // 2026-10-17: next's first three Run migrations; next's code writes rows.
    await applyPendingMigrations(pool, webDir, folder((name) => isBefore(name) || nextFirst.has(name)));
    await pool.query(`
      insert into cloud_runtimes (id, owner_team_id) values ('${ids(1)}', 'team-a');
      insert into runs (id, user_id, request_digest, source, recipe, status, cancel_requested_at)
        values ('${ids(10)}', 'user-a', 'd1', '{"commit":"c"}', 'recipe', 'cancelling', now());
      insert into run_attempts (id, run_id, ordinal, status, runtime_id, lease_token, lease_generation, lease_expires_at, provider_workspace_id)
        values ('${ids(20)}', '${ids(10)}', 0, 'leased', '${ids(1)}', 'tok', 2, now(), 'ws');
      insert into run_events (id, run_id, attempt_id, sequence, attempt_sequence, external_id, kind)
        values ('${ids(30)}', '${ids(10)}', '${ids(20)}', 1, 1, 'e1', 'attempt.heartbeat');
      insert into run_artifacts (id, run_id, attempt_id, name, media_type, size_bytes, digest, uri)
        values ('${ids(40)}', '${ids(10)}', '${ids(20)}', 'log', 'text/plain', 3, '${digest("d")}', 'r2://bucket/log');
    `);
    // 2026-10-18: main's four Run migrations; main's code writes rows.
    await applyPendingMigrations(pool, webDir, folder((name) => isBefore(name) || nextFirst.has(name) || mainRunMigrations.includes(name)));
    await pool.query(`
      insert into runs (id, user_id, request_digest, source, recipe, owner_team_id, spec) values ('${ids(11)}', 'user-b', 'd2', '{}', 'recipe', 'team-b', '{}');
      insert into run_attempts (id, run_id, ordinal, variant, cleanup_state) values ('${ids(21)}', '${ids(11)}', 0, '{"b":2}', 'retained');
      insert into run_events (id, run_id, sequence, kind) values ('${ids(31)}', '${ids(11)}', 1, 'run.cancelled');
      insert into run_artifacts (id, run_id, attempt_id, name, digest, payload, size_bytes) values ('${ids(41)}', '${ids(11)}', '${ids(21)}', 'receipt', '${digest("e")}', '{"k":2}', 7);
    `);
    const before = await snapshotRows(pool);

    expect(await applyRealFolder(pool)).toBeGreaterThan(runModelSteps.length);
    expectRowsKept(before, await snapshotRows(pool));
    expect(await missingFromNext(pool)).toEqual({});
    await expectReplayIsNoOp(pool);
    catalogs.hybrid = await catalog(pool);
  });

  dbTest("the three shapes end the same, apart from two leftovers of main's model", () => {
    expect(Object.keys(catalogs).sort()).toEqual(["empty", "hybrid", "main"]);
    expect(catalogDifferences(catalogs.hybrid, catalogs.empty)).toEqual([]);
    // From main's 20261017150000_run_api, which creates run_attempts only where next's run_api has not:
    // - run_attempts_lease_idx is main's (status, lease_until) on main's shape and next's (status,
    //   lease_expires_at) elsewhere; the contract step drops it and renames run_attempts_lease_expires_idx.
    // - run_attempts_ordinal_check (ordinal >= 0) exists on main's shape only.
    expect(catalogDifferences(catalogs.main, catalogs.empty)).toEqual(["constraint run_attempts_ordinal_check", "index run_attempts_lease_idx"]);
    expect(catalogs.main["index run_attempts_lease_idx"]).toContain("lease_until");
    expect(catalogs.empty["index run_attempts_lease_idx"]).toContain("lease_expires_at");
  });
});
