import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getTableConfig } from "drizzle-orm/pg-core";
import { runAttempts, runs } from "../db/schema";
import { applyPendingMigrations, readNoTransactionMigrations } from "../scripts/cloud-vm/apply-migrations.mjs";

// next's 20261016000000_run_api and 20261017000000_runtime_persistence were rewritten in place to be
// replay-safe (B1 of leo-workspace notes/web-next-to-cmux-com.md). This applies the real folder,
// through the runner production uses, onto the three starting shapes those two files must survive.
//
// Fixtures:
// - tests/fixtures/run-migrations/main/*.sql: main's four Run migrations, byte for byte from
//   manaflow-ai/cmux main at ddf1d3d9eaf5faeb3bdabc0705f964f0c47f1b4a (unchanged through main
//   c584e7acc4e07ba917efb08e75a73f573f175817).
// - tests/fixtures/run-migrations/next-before-b1/*.sql: the two migrations as they were before the
//   rewrite, from feat-cmux-next at 67d25dd906fd5325ee2911afd09a43c12fc7a150 (last changed in
//   8f4bb88e8cdc, #21337), which next's databases and staging recorded.
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { Pool } = requireFromWeb("pg");
type PgPool = InstanceType<typeof Pool>;

const realFolder = path.join(webDir, "db/migrations");
const noTransaction = readNoTransactionMigrations(path.join(webDir, "db/no-transaction-migrations.json"));
const fixtureDir = path.join(webDir, "tests/fixtures/run-migrations");
const rewritten = ["20261016000000_run_api", "20261017000000_runtime_persistence"];
const firstRunMigration = rewritten[0];
const sqlFiles = (dir: string) => readdirSync(dir).filter((file) => file.endsWith(".sql")).sort()
  .map((file) => ({ name: file.replace(/\.sql$/, ""), sql: readFileSync(path.join(dir, file), "utf8") }));
const mainRunMigrations = sqlFiles(path.join(fixtureDir, "main"));
const oldVersions = sqlFiles(path.join(fixtureDir, "next-before-b1"));
// B2's reconcile steps (section 4 steps 1 to 3 of the note), byte for byte the same files on main.
const runModelSteps = ["20261028000000_run_model_enums", "20261028000100_run_model_expand", "20261028000200_run_model_validate"];

const scratchRoot = mkdtempSync(path.join(tmpdir(), "cmux-run-migrations-replay-"));
let folderCount = 0;
/** A copy of the real folder: only migrations sorting before `before`, plus `extra`, with `replace` swapped in. */
function folder(options: { before?: string; through?: string; extra?: ReadonlyArray<{ name: string; sql: string }>; replace?: ReadonlyArray<{ name: string; sql: string }> }) {
  const root = path.join(scratchRoot, `folder-${++folderCount}`);
  for (const name of readdirSync(realFolder)) {
    if (options.before && name >= options.before) continue;
    if (options.through && name > options.through) continue;
    cpSync(path.join(realFolder, name), path.join(root, name), { recursive: true });
  }
  for (const migration of [...(options.extra ?? []), ...(options.replace ?? [])]) {
    mkdirSync(path.join(root, migration.name), { recursive: true });
    writeFileSync(path.join(root, migration.name, "migration.sql"), migration.sql);
  }
  // The real no-transaction list, cut to the folders this copy has (the runner refuses a listed name with no folder).
  const included = new Set(readdirSync(root));
  const noTransactionManifest = `${root}.no-transaction-migrations.json`;
  writeFileSync(noTransactionManifest, JSON.stringify({ migrations: [...noTransaction].filter((name) => included.has(name)) }));
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
    await adminPool?.query(`drop database if exists "${name}" with (force)`);
  }
  await adminPool?.end();
  rmSync(scratchRoot, { recursive: true, force: true });
});

async function freshDatabase(): Promise<PgPool> {
  if (!adminPool) throw new Error("CMUX_DB_TEST=1 is required");
  const name = `cmux_run_replay_${process.pid}_${databasePools.length}`;
  await adminPool.query(`drop database if exists "${name}" with (force)`);
  await adminPool.query(`create database "${name}"`);
  const url = new URL(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? "");
  url.pathname = `/${name}`;
  const pool = new Pool({ connectionString: url.href, max: 1 });
  databasePools.push({ name, pool });
  return pool;
}

/** Applies the real web/db/migrations folder, as migrate-planetscale.mjs does. */
const applyRealFolder = (pool: PgPool) => applyPendingMigrations(pool, webDir);

async function journal(pool: PgPool) {
  return (await pool.query("select hash, name from drizzle.__drizzle_migrations order by id")).rows as Array<{ hash: string; name: string }>;
}

async function columns(pool: PgPool, table: string) {
  const result = await pool.query(
    "select column_name from information_schema.columns where table_schema = 'public' and table_name = $1",
    [table],
  );
  return new Set(result.rows.map((row: { column_name: string }) => row.column_name));
}

/** schema.ts columns of runs and run_attempts that the database lacks. */
async function missingSchemaColumns(pool: PgPool) {
  const missing: Record<string, string[]> = {};
  for (const table of [runs, runAttempts]) {
    const config = getTableConfig(table);
    const present = await columns(pool, config.name);
    missing[config.name] = config.columns.map((column) => column.name).filter((name) => !present.has(name)).sort();
  }
  return missing;
}

/** Everything a migration can create in the public schema, in a form two databases can be compared by. */
async function catalog(pool: PgPool) {
  const query = async (sql: string) => (await pool.query(sql)).rows;
  return {
    columns: await query(`select table_name, ordinal_position, column_name, data_type, udt_name, column_default, is_nullable
      from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position`),
    constraints: await query(`select conrelid::regclass::text as table_name, conname, contype, convalidated, pg_get_constraintdef(oid) as def
      from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`),
    indexes: await query("select tablename, indexname, indexdef from pg_indexes where schemaname = 'public' order by 1, 2"),
    enums: await query(`select t.typname, array_agg(e.enumlabel order by e.enumsortorder)::text as labels
      from pg_type t join pg_enum e on e.enumtypid = t.oid where t.typnamespace = 'public'::regnamespace group by 1 order by 1`),
  };
}

describe("Run migrations replay onto every starting shape", () => {
  dbTest("an empty database gets exactly what the old two migrations created, and a replay changes nothing", async () => {
    const before = await freshDatabase();
    await applyPendingMigrations(before, webDir, folder({ replace: oldVersions }));
    const pool = await freshDatabase();
    await applyRealFolder(pool);

    expect(await catalog(pool)).toEqual(await catalog(before));
    expect((await journal(pool)).map((row) => row.name)).toEqual((await journal(before)).map((row) => row.name));
    expect(await missingSchemaColumns(pool)).toEqual({ runs: [], run_attempts: [] });

    // Forget the two ledger rows: the rewritten files run again over their own output.
    const snapshot = await catalog(pool);
    await pool.query("delete from drizzle.__drizzle_migrations where name = any($1)", [rewritten]);
    expect(await applyRealFolder(pool)).toBe(2);
    expect(await catalog(pool)).toEqual(snapshot);
  });

  dbTest("a database with main's Run model, holding rows, migrates, keeps every row and gets next's columns", async () => {
    const pool = await freshDatabase();
    await applyPendingMigrations(pool, webDir, folder({ before: firstRunMigration, extra: mainRunMigrations }));
    const orphanRuntime = "00000000-0000-4000-8000-000000000001";
    await pool.query(`
      insert into cloud_runtimes (id, owner_team_id) values ('00000000-0000-4000-8000-0000000000aa', 'team-a');
      insert into runs (id, user_id, request_digest, source, recipe, owner_team_id, spec)
        values ('00000000-0000-4000-8000-000000000010', 'user-a', 'digest', '{}', 'recipe', 'team-a', '{}');
      insert into run_attempts (id, run_id, ordinal, variant, runtime_id, status)
        values ('00000000-0000-4000-8000-000000000020', '00000000-0000-4000-8000-000000000010', 0, '{}', '${orphanRuntime}', 'running');
      insert into run_events (run_id, attempt_id, sequence, kind)
        values ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000020', 1, 'run.cancelled');
      insert into run_artifacts (run_id, attempt_id, name, digest, payload, size_bytes)
        values ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000020', 'a', 'sha256:x', '{"k":1}', 7);
    `);

    expect(await applyRealFolder(pool)).toBeGreaterThan(0);
    const names = (await journal(pool)).map((row) => row.name);
    for (const name of [...mainRunMigrations.map((m) => m.name), ...rewritten]) expect(names).toContain(name);

    // main's tables keep their rows. The one rewrite: run_model_validate sets the orphan runtime_id
    // (main's column had no FK) to NULL before it validates the FK run_model_expand added.
    expect((await pool.query("select runtime_id::text, variant, status::text from run_attempts")).rows)
      .toEqual([{ runtime_id: null, variant: {}, status: "running" }]);
    expect((await pool.query("select owner_team_id from runs")).rows).toEqual([{ owner_team_id: "team-a" }]);
    expect((await pool.query("select kind::text from run_events")).rows).toEqual([{ kind: "run.cancelled" }]);
    expect((await pool.query("select payload from run_artifacts")).rows).toEqual([{ payload: { k: 1 } }]);
    expect((await pool.query("select lifecycle_state::text from cloud_runtimes")).rows).toEqual([{ lifecycle_state: "released" }]);
    const runtimeForeignKeys = await pool.query(`select c.conname, c.convalidated from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
      where c.conrelid = 'run_attempts'::regclass and c.contype = 'f' and a.attname = 'runtime_id'`);
    expect(runtimeForeignKeys.rows).toEqual([{ conname: "run_attempts_runtime_id_fkey", convalidated: true }]);
    // main's artifact row breaks next's digest check ('sha256:x'): the row is kept and that check stays NOT VALID.
    expect((await pool.query(`select conname, convalidated from pg_constraint where conrelid = 'run_artifacts'::regclass and contype = 'c' order by conname`)).rows)
      .toEqual([{ conname: "run_artifacts_digest_check", convalidated: false }, { conname: "run_artifacts_size_check", convalidated: true }]);
    // next's runtime index exists; next's same-named lease index did not replace main's.
    const indexes = (await pool.query("select indexname, indexdef from pg_indexes where tablename = 'run_attempts'")).rows as Array<{ indexname: string; indexdef: string }>;
    expect(indexes.map((index) => index.indexname)).toContain("run_attempts_runtime_idx");
    expect(indexes.find((index) => index.indexname === "run_attempts_lease_idx")?.indexdef).toContain("lease_until");

    expect(await missingSchemaColumns(pool)).toEqual({ runs: [], run_attempts: [] });

    // A second replay of the two rewritten files over main's shape is also a no-op.
    const snapshot = await catalog(pool);
    await pool.query("delete from drizzle.__drizzle_migrations where name = any($1)", [rewritten]);
    expect(await applyRealFolder(pool)).toBe(2);
    expect(await catalog(pool)).toEqual(snapshot);
  });

  dbTest("on next's own shape the run_model steps change nothing but add one index, and keep every row", async () => {
    const pool = await freshDatabase();
    await applyPendingMigrations(pool, webDir, folder({ before: runModelSteps[0] }));
    await pool.query(`
      insert into cloud_runtimes (id, owner_team_id) values ('00000000-0000-4000-8000-0000000000aa', 'team-a');
      insert into runs (id, user_id, request_digest, source, recipe, status) values ('00000000-0000-4000-8000-000000000010', 'user-a', 'digest', '{}', 'recipe', 'cancelling');
      insert into run_attempts (id, run_id, ordinal, status, runtime_id, lease_token, lease_generation)
        values ('00000000-0000-4000-8000-000000000020', '00000000-0000-4000-8000-000000000010', 0, 'leased', '00000000-0000-4000-8000-0000000000aa', 'tok', 3);
      insert into run_events (run_id, attempt_id, sequence, attempt_sequence, external_id, kind)
        values ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000020', 1, 1, 'e1', 'attempt.heartbeat');
      insert into run_artifacts (run_id, attempt_id, name, size_bytes, digest, uri)
        values ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000020', 'a', 1, 'sha256:${"a".repeat(64)}', 'r2://b/a');
    `);
    const snapshotRows = async () => Object.fromEntries(await Promise.all(["runs", "run_attempts", "run_events", "run_artifacts", "cloud_runtimes"]
      .map(async (table) => [table, (await pool.query(`select to_jsonb(t) as row from "${table}" t order by id`)).rows])));
    const before = { catalog: await catalog(pool), rows: await snapshotRows() };

    // Only through the run_model steps: later migrations add their own objects.
    expect(await applyPendingMigrations(pool, webDir, folder({ through: runModelSteps.at(-1) }))).toBe(runModelSteps.length);
    const after = await catalog(pool);
    expect({ ...after, indexes: [] }).toEqual({ ...before.catalog, indexes: [] });
    // The one addition: next's (status, lease_expires_at) index under the name main's databases need while
    // main's own run_attempts_lease_idx is still in use; the contract step renames it.
    type Index = { indexname: string };
    const added = after.indexes.filter((index: Index) => !before.catalog.indexes.some((old: Index) => old.indexname === index.indexname));
    expect(added.map((index: Index) => index.indexname)).toEqual(["run_attempts_lease_expires_idx"]);
    expect(after.indexes.filter((index: Index) => index.indexname !== "run_attempts_lease_expires_idx")).toEqual(before.catalog.indexes);
    expect(await snapshotRows()).toEqual(before.rows);
  });

  // next's databases recorded the old versions alone; staging recorded them and then main's four (the hybrid).
  for (const [label, extra] of [["next's", []], ["staging's hybrid", mainRunMigrations]] as const) {
    dbTest(`a database that recorded the old versions (${label}) runs neither again and keeps their ledger rows`, async () => {
      const pool = await freshDatabase();
      await applyPendingMigrations(pool, webDir, folder({ before: "20261017010000", replace: oldVersions, extra }));
      const recorded = (await journal(pool)).filter((row) => rewritten.includes(row.name));
      expect(recorded).toHaveLength(2);

      expect(await applyRealFolder(pool)).toBeGreaterThan(0);
      // The ledger matches by name: the old hashes stay, and the rewritten files never ran here.
      expect((await journal(pool)).filter((row) => rewritten.includes(row.name))).toEqual(recorded);
      expect(await missingSchemaColumns(pool)).toEqual({ runs: [], run_attempts: [] });
      expect(await applyRealFolder(pool)).toBe(0);
    });
  }
});
