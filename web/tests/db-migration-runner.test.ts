import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  applyPendingMigrations,
  noTransactionProblems,
  readNoTransactionMigrations,
} from "../scripts/cloud-vm/apply-migrations.mjs";

// The migration runner production (migrate-planetscale.mjs), CI and local
// databases share. DB cases build throwaway databases next to the shared test
// database and migrate fixture folders into them.
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
const { Pool } = requireFromWeb("pg");

type PgPool = InstanceType<typeof Pool>;
type Migration = { readonly name: string; readonly sql: string };

const scratchRoot = mkdtempSync(path.join(tmpdir(), "cmux-migration-runner-"));
let fixtureCount = 0;

/** A migrations folder plus manifest; `marked` lists the folders to run outside a transaction. */
function fixture(migrations: ReadonlyArray<Migration>, marked: ReadonlyArray<string> = []) {
  const root = path.join(scratchRoot, `fixture-${++fixtureCount}`);
  const migrationsFolder = path.join(root, "migrations");
  for (const migration of migrations) {
    mkdirSync(path.join(migrationsFolder, migration.name), { recursive: true });
    writeFileSync(path.join(migrationsFolder, migration.name, "migration.sql"), migration.sql);
  }
  const noTransactionManifest = path.join(root, "no-transaction-migrations.json");
  writeFileSync(noTransactionManifest, JSON.stringify({ migrations: marked }));
  return { migrationsFolder, noTransactionManifest };
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
  const name = `cmux_migration_runner_${process.pid}_${databasePools.length}`;
  await adminPool.query(`drop database if exists "${name}" with (force)`);
  await adminPool.query(`create database "${name}"`);
  const url = new URL(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? "");
  url.pathname = `/${name}`;
  // max 1, as production's operator pool: the runner must never need a second connection.
  const pool = new Pool({ connectionString: url.href, max: 1 });
  databasePools.push({ name, pool });
  return pool;
}

async function journal(pool: PgPool) {
  const result = await pool.query(
    "select hash, created_at::text as created_at, name, applied_at from drizzle.__drizzle_migrations order by id",
  );
  return result.rows as Array<{ hash: string; created_at: string; name: string; applied_at: Date }>;
}

async function indexValid(pool: PgPool, indexName: string) {
  const result = await pool.query(
    "select i.indisvalid as valid from pg_class c join pg_index i on i.indexrelid = c.oid where c.relname = $1",
    [indexName],
  );
  return (result.rows[0]?.valid as boolean | undefined) ?? null;
}

async function tableExists(pool: PgPool, tableName: string) {
  const result = await pool.query("select to_regclass($1)::text as name", [tableName]);
  return result.rows[0]?.name != null;
}

/** drizzle's own migrate(), which production used before this runner. */
async function drizzleMigrate(pool: PgPool, migrationsFolder: string) {
  const { drizzle } = requireFromWeb("drizzle-orm/node-postgres");
  const { migrate } = requireFromWeb("drizzle-orm/node-postgres/migrator");
  await migrate(drizzle({ client: pool }), { migrationsFolder });
}

const createTable = { name: "20260101000000_create_items", sql: `CREATE TABLE "items" ("id" integer PRIMARY KEY, "v" integer);` };
const concurrentIndex = {
  name: "20260101000100_items_v_index",
  sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "items_v_idx" ON "items" ("v");`,
};
const addColumn = { name: "20260101000200_items_w", sql: `ALTER TABLE "items" ADD COLUMN "w" integer;` };

describe("migration folder guard", () => {
  test("every migration with CONCURRENTLY is listed in web/db/no-transaction-migrations.json", () => {
    const migrations = readMigrationFiles({ migrationsFolder: path.join(webDir, "db/migrations") });
    const marked = readNoTransactionMigrations(path.join(webDir, "db/no-transaction-migrations.json"));
    expect(noTransactionProblems(migrations, marked)).toEqual([]);
  });

  test("refuses an unlisted CONCURRENTLY migration, a retry-unsafe listed index and a stale entry", () => {
    const { migrationsFolder } = fixture([
      createTable,
      concurrentIndex,
      { name: "20260101000300_unsafe", sql: `CREATE INDEX CONCURRENTLY "items_w_idx" ON "items" ("w");` },
      // A comment that mentions CONCURRENTLY is not a statement.
      { name: "20260101000400_comment", sql: `-- not CONCURRENTLY\nALTER TABLE "items" ADD COLUMN "x" integer;` },
    ]);
    const problems = noTransactionProblems(
      readMigrationFiles({ migrationsFolder }),
      new Set(["20260101000300_unsafe", "20260101000500_missing"]),
    );
    expect(problems).toEqual([
      "20260101000500_missing: listed in no-transaction-migrations.json but has no migration folder",
      "20260101000100_items_v_index: uses CONCURRENTLY, which cannot run in a transaction; add it to web/db/no-transaction-migrations.json",
      `20260101000300_unsafe: write CREATE INDEX CONCURRENTLY IF NOT EXISTS "name" ON ... so a retry is safe`,
    ]);
  });

  test("the production migrator applies through applyPendingMigrations, not drizzle's single-transaction migrate()", () => {
    const source = readFileSync(path.join(webDir, "scripts/cloud-vm/migrate-planetscale.mjs"), "utf8");
    expect(source).toContain(`import { applyPendingMigrations } from "./apply-migrations.mjs";`);
    expect(source).toContain("await applyPendingMigrations(pool, webDir)");
    expect(source).not.toContain("drizzle-orm/node-postgres/migrator");
  });
});

describe("applyPendingMigrations on Postgres", () => {
  dbTest("applies a listed CONCURRENTLY migration in its place, with drizzle's journal rows", async () => {
    const folder = fixture([createTable, concurrentIndex, addColumn], [concurrentIndex.name]);

    // drizzle's migrate() (production's runner before this fix) cannot apply the folder.
    const drizzlePool = await freshDatabase();
    const drizzleError = await drizzleMigrate(drizzlePool, folder.migrationsFolder).then(() => null, (error) => error);
    expect(drizzleError?.cause?.code ?? drizzleError?.code).toBe("25001"); // active_sql_transaction
    expect(await tableExists(drizzlePool, "items")).toBe(false);

    const pool = await freshDatabase();
    expect(await applyPendingMigrations(pool, webDir, folder)).toBe(3);
    expect(await indexValid(pool, "items_v_idx")).toBe(true);
    const local = readMigrationFiles({ migrationsFolder: folder.migrationsFolder });
    expect((await journal(pool)).map(({ hash, created_at, name }) => ({ hash, created_at, name }))).toEqual(
      local.map((migration: { hash: string; folderMillis: number; name: string }) => ({
        hash: migration.hash,
        created_at: String(migration.folderMillis),
        name: migration.name,
      })),
    );
  });

  dbTest("writes the same journal rows as drizzle's migrate() for transactional migrations", async () => {
    const folder = fixture([createTable, addColumn]);
    const drizzlePool = await freshDatabase();
    await drizzleMigrate(drizzlePool, folder.migrationsFolder);
    const pool = await freshDatabase();
    await applyPendingMigrations(pool, webDir, folder);
    const rows = async (target: PgPool) => (await journal(target)).map(({ hash, created_at, name }) => ({ hash, created_at, name }));
    expect(await rows(pool)).toEqual(await rows(drizzlePool));
  });

  dbTest("re-running is a no-op", async () => {
    const folder = fixture([createTable, concurrentIndex, addColumn], [concurrentIndex.name]);
    const pool = await freshDatabase();
    await applyPendingMigrations(pool, webDir, folder);
    const before = await journal(pool);
    expect(await applyPendingMigrations(pool, webDir, folder)).toBe(0);
    expect(await journal(pool)).toEqual(before);
  });

  dbTest("rebuilds the INVALID index an interrupted CREATE INDEX CONCURRENTLY left", async () => {
    const uniqueIndex = {
      name: "20260101000100_items_v_unique",
      sql: `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "items_v_unique" ON "items" ("v");`,
    };
    const seed = { name: "20260101000050_seed", sql: `INSERT INTO "items" ("id", "v") VALUES (1, 7), (2, 7);` };
    const folder = fixture([createTable, seed, uniqueIndex], [uniqueIndex.name]);
    const pool = await freshDatabase();

    // The duplicate fails the build part way and leaves an INVALID index behind.
    const failure = await applyPendingMigrations(pool, webDir, folder).then(() => null, (error) => error);
    expect(failure?.code).toBe("23505");
    expect(await indexValid(pool, "items_v_unique")).toBe(false);
    expect((await journal(pool)).map((row) => row.name)).toEqual([createTable.name, seed.name]);

    // IF NOT EXISTS alone would skip the INVALID index; the retry drops and rebuilds it.
    await pool.query(`DELETE FROM "items" WHERE "id" = 2`);
    expect(await applyPendingMigrations(pool, webDir, folder)).toBe(1);
    expect(await indexValid(pool, "items_v_unique")).toBe(true);
    expect((await journal(pool)).map((row) => row.name)).toEqual([createTable.name, seed.name, uniqueIndex.name]);
  });

  dbTest("a failing statement rolls back its whole unlisted migration and stops the run", async () => {
    const failing = {
      name: "20260101000100_half",
      sql: `CREATE TABLE "half" ("id" integer);--> statement-breakpoint\nSELECT 1 / 0;`,
    };
    const folder = fixture([createTable, failing, addColumn]);
    const pool = await freshDatabase();
    const failure = await applyPendingMigrations(pool, webDir, folder).then(() => null, (error) => error);
    expect(failure?.code).toBe("22012"); // division_by_zero
    expect(await tableExists(pool, "half")).toBe(false);
    expect((await journal(pool)).map((row) => row.name)).toEqual([createTable.name]);
    const columns = await pool.query(`select column_name from information_schema.columns where table_name = 'items' and column_name = 'w'`);
    expect(columns.rows).toEqual([]);
  });

  dbTest("commits an enum ADD VALUE before a later migration uses the value", async () => {
    const createEnum = {
      name: "20260101000000_state",
      sql: `CREATE TYPE "state" AS ENUM ('a');--> statement-breakpoint\nCREATE TABLE "things" ("s" "state");`,
    };
    const addValue = { name: "20260101000100_state_b", sql: `ALTER TYPE "state" ADD VALUE IF NOT EXISTS 'b';` };
    const useValue = { name: "20260101000200_use_b", sql: `INSERT INTO "things" ("s") VALUES ('b');` };
    const pool = await freshDatabase();
    await applyPendingMigrations(pool, webDir, fixture([createEnum]));

    // drizzle's migrate() runs both pending migrations in one transaction: unsafe use of a new enum value.
    const drizzlePool = await freshDatabase();
    await drizzleMigrate(drizzlePool, fixture([createEnum]).migrationsFolder);
    const drizzleError = await drizzleMigrate(drizzlePool, fixture([createEnum, addValue, useValue]).migrationsFolder)
      .then(() => null, (error) => error);
    expect(drizzleError?.cause?.code ?? drizzleError?.code).toBe("55P04");

    expect(await applyPendingMigrations(pool, webDir, fixture([createEnum, addValue, useValue]))).toBe(2);
    expect((await pool.query(`select "s"::text as s from "things"`)).rows).toEqual([{ s: "b" }]);
  });

  dbTest("refuses an unlisted CONCURRENTLY migration before running anything", async () => {
    const folder = fixture([createTable, concurrentIndex]);
    const pool = await freshDatabase();
    const failure = await applyPendingMigrations(pool, webDir, folder).then(() => null, (error) => error);
    expect(String(failure?.message)).toContain("migrations refused before any ran");
    expect(await tableExists(pool, "items")).toBe(false);
  });
});
