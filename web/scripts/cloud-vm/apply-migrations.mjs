import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

// Postgres refuses CONCURRENTLY forms (CREATE/DROP/REINDEX INDEX, DETACH
// PARTITION) inside a transaction block.
const concurrentlyPattern = /\bCONCURRENTLY\b/i;
const concurrentIndexPattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY/i;
const concurrentIndexNamePattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY(?:\s+IF\s+NOT\s+EXISTS)?\s+"([^"]+)"/i;
const concurrentIndexTargetPattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY(?:\s+IF\s+NOT\s+EXISTS)?\s+"[^"]+"\s+ON\s+(?:ONLY\s+)?(?:(?:"([^"]+)"|([A-Za-z_][\w$]*))\.)?(?:"([^"]+)"|([A-Za-z_][\w$]*))/i;
const rerunSafeConcurrentIndexPattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY\s+IF\s+NOT\s+EXISTS\s+"[^"]+"\s+ON\s/i;

const withoutComments = (sql) => sql.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");

/**
 * The migrations listed in `web/db/no-transaction-migrations.json`. The list
 * lives beside the folder, not as a marker inside migration.sql, because
 * drizzle records sha256(migration.sql) in __drizzle_migrations: editing an
 * applied file would make its recorded hash differ between databases.
 */
export function readNoTransactionMigrations(manifestPath) {
  if (!existsSync(manifestPath)) return new Set();
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (!Array.isArray(manifest?.migrations) || manifest.migrations.some((name) => typeof name !== "string")) {
    throw new Error(`${manifestPath}: "migrations" must be a list of migration folder names`);
  }
  return new Set(manifest.migrations);
}

/** Problems that would make a migration fail or unsafe to retry; empty when the folder is consistent. */
export function noTransactionProblems(migrations, marked) {
  const problems = [];
  const names = new Set(migrations.map((migration) => migration.name));
  for (const name of marked) {
    if (!names.has(name)) problems.push(`${name}: listed in no-transaction-migrations.json but has no migration folder`);
  }
  for (const migration of migrations) {
    const statements = migration.sql.map(withoutComments);
    if (!marked.has(migration.name)) {
      if (statements.some((statement) => concurrentlyPattern.test(statement))) {
        problems.push(`${migration.name}: uses CONCURRENTLY, which cannot run in a transaction; add it to web/db/no-transaction-migrations.json`);
      }
      continue;
    }
    for (const statement of statements) {
      if (concurrentIndexPattern.test(statement) && !rerunSafeConcurrentIndexPattern.test(statement)) {
        problems.push(`${migration.name}: write CREATE INDEX CONCURRENTLY IF NOT EXISTS "name" ON ... so a retry is safe`);
      }
    }
  }
  return problems;
}

async function insertJournalRow(client, migration) {
  // The same row drizzle's migrate() writes: sha256 of migration.sql, the
  // folder timestamp in milliseconds, and the folder name.
  await client.query(
    "insert into drizzle.__drizzle_migrations (hash, created_at, name) values ($1, $2, $3)",
    [migration.hash, migration.folderMillis, migration.name ?? null],
  );
}

function concurrentIndexOf(statement) {
  const indexName = statement.match(concurrentIndexNamePattern)?.[1];
  const target = statement.match(concurrentIndexTargetPattern);
  const tableName = target?.[3] ?? target?.[4];
  if (!indexName || !tableName) return undefined;
  return { indexName, schemaName: target?.[1] ?? target?.[2] ?? "public", tableName };
}

async function indexValidity(client, { indexName, schemaName, tableName }) {
  const result = await client.query(
    "select n.nspname as schema_name, c.relname as index_name, i.indisvalid as valid from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_index i on i.indexrelid = c.oid join pg_class t on t.oid = i.indrelid join pg_namespace tn on tn.oid = t.relnamespace where c.relname = $1 and n.nspname = $2 and t.relname = $3 and tn.nspname = $2",
    [indexName, schemaName, tableName],
  );
  return result.rows[0];
}

// A failed CREATE INDEX CONCURRENTLY leaves an INVALID index that IF NOT
// EXISTS would then skip; drop it so the retry builds a valid one.
async function dropInvalidConcurrentIndex(client, index) {
  const existing = await indexValidity(client, index);
  if (!existing || existing.valid) return;
  const quoteIdentifier = (value) => `"${String(value).replaceAll('"', '""')}"`;
  await client.query(
    `drop index concurrently if exists ${quoteIdentifier(existing.schema_name)}.${quoteIdentifier(existing.index_name)}`,
  );
}

/**
 * A listed migration runs with no transaction: one statement at a time, then
 * its journal row. A failure leaves the statements before it applied and no
 * journal row, so the next run starts the migration again from its first
 * statement. Every statement in a listed migration must therefore be safe to
 * run twice (IF NOT EXISTS, VALIDATE CONSTRAINT, ...), and an INVALID index
 * left by an interrupted CREATE INDEX CONCURRENTLY is dropped and rebuilt.
 */
async function applyWithoutTransaction(client, migration) {
  const indexes = [];
  for (const statement of migration.sql) {
    const index = concurrentIndexPattern.test(statement) ? concurrentIndexOf(statement) : undefined;
    if (index) {
      await dropInvalidConcurrentIndex(client, index);
      indexes.push(index);
    }
    await client.query(statement);
  }
  for (const index of indexes) {
    const state = await indexValidity(client, index);
    if (!state?.valid) throw new Error(`${migration.name}: index ${index.indexName} is not valid after CREATE INDEX CONCURRENTLY`);
  }
  await insertJournalRow(client, migration);
}

async function applyInTransaction(client, migration) {
  try {
    await client.query("begin");
    for (const statement of migration.sql) await client.query(statement);
    await insertJournalRow(client, migration);
    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  }
}

/**
 * Applies the pending migrations in `web/db/migrations` through a `pg` pool.
 * Production (migrate-planetscale.mjs), CI and local databases
 * (scripts/db-migrate.mjs) all apply migrations through this function.
 *
 * Pending is drizzle's rule (a folder whose name is not in the journal), in
 * folder order. Each migration runs in its own transaction with its journal
 * row, so an `ALTER TYPE ... ADD VALUE` is committed before a later migration
 * uses the value. A migration listed in `web/db/no-transaction-migrations.json`
 * (anything with CONCURRENTLY) runs outside a transaction in its place in
 * that order; see applyWithoutTransaction. drizzle's own migrate() runs every
 * pending migration in one transaction, where CONCURRENTLY fails.
 *
 * @param {{ migrationsFolder?: string, noTransactionManifest?: string }} [options] fixture paths for tests
 */
export async function applyPendingMigrations(pool, webDir, options = {}) {
  const requireFromWeb = createRequire(path.join(webDir, "package.json"));
  const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
  const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");
  const migrationsFolder = options.migrationsFolder ?? path.join(webDir, "db/migrations");
  const manifestPath = options.noTransactionManifest ?? path.join(webDir, "db/no-transaction-migrations.json");
  const migrations = readMigrationFiles({ migrationsFolder });
  const marked = readNoTransactionMigrations(manifestPath);
  const problems = noTransactionProblems(migrations, marked);
  if (problems.length) throw new Error(`migrations refused before any ran: ${problems.join("; ")}`);

  const client = await pool.connect();
  let locked = false;
  try {
    await client.query("select pg_advisory_lock(hashtextextended($1, 0))", ["cmux:migrations"]);
    locked = true;
    await client.query("CREATE SCHEMA IF NOT EXISTS drizzle");
    await client.query(`
    CREATE TABLE IF NOT EXISTS drizzle.__drizzle_migrations (
      id SERIAL PRIMARY KEY,
      hash text NOT NULL,
      created_at bigint,
      name text,
      applied_at timestamp with time zone DEFAULT now()
    )
    `);
    const applied = await client.query("select id, hash, created_at, name from drizzle.__drizzle_migrations");
    const pending = getMigrationsToRun({ localMigrations: migrations, dbMigrations: applied.rows });
    for (const migration of pending) {
      if (marked.has(migration.name)) {
        await applyWithoutTransaction(client, migration);
      } else {
        await applyInTransaction(client, migration);
      }
    }
    return pending.length;
  } finally {
    try {
      if (locked) await client.query("select pg_advisory_unlock(hashtextextended($1, 0))", ["cmux:migrations"]);
    } finally {
      client.release();
    }
  }
}
