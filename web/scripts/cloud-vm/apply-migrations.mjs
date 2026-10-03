import { createRequire } from "node:module";
import path from "node:path";

const concurrentIndexPattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY/i;
const concurrentIndexNamePattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY(?:\s+IF\s+NOT\s+EXISTS)?\s+"([^"]+)"/i;
const concurrentIndexTargetPattern = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY(?:\s+IF\s+NOT\s+EXISTS)?\s+"[^"]+"\s+ON\s+(?:ONLY\s+)?(?:(?:"([^"]+)"|([A-Za-z_][\w$]*))\.)?(?:"([^"]+)"|([A-Za-z_][\w$]*))/i;

async function recordMigration(client, migration) {
  for (const statement of migration.sql) await client.query(statement);
  await client.query(
    "insert into drizzle.__drizzle_migrations (hash, created_at, name) values ($1, $2, $3)",
    [migration.hash, migration.folderMillis, migration.name ?? null],
  );
}

// A failed CREATE INDEX CONCURRENTLY leaves an invalid index that
// IF NOT EXISTS would then skip; drop it so the retry builds a valid one.
async function dropInvalidConcurrentIndex(pool, migration) {
  const indexStatement = migration.sql.find((statement) => concurrentIndexPattern.test(statement));
  const indexName = indexStatement?.match(concurrentIndexNamePattern)?.[1];
  const target = indexStatement?.match(concurrentIndexTargetPattern);
  const schemaName = target?.[1] ?? target?.[2] ?? "public";
  const tableName = target?.[3] ?? target?.[4];
  if (!indexName || !tableName) return;
  const existing = await pool.query(
    "select n.nspname as schema_name, c.relname as index_name from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_index i on i.indexrelid = c.oid join pg_class t on t.oid = i.indrelid join pg_namespace tn on tn.oid = t.relnamespace where c.relname = $1 and n.nspname = $2 and i.indisvalid = false and t.relname = $3 and tn.nspname = $2",
    [indexName, schemaName, tableName],
  );
  const invalid = existing.rows[0];
  if (!invalid) return;
  const quoteIdentifier = (value) => `"${String(value).replaceAll('"', '""')}"`;
  await pool.query(
    `drop index concurrently if exists ${quoteIdentifier(invalid.schema_name)}.${quoteIdentifier(invalid.index_name)}`,
  );
}

async function applyInTransaction(client, migration) {
  try {
    await client.query("begin");
    await recordMigration(client, migration);
    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  }
}

/**
 * Applies the pending migrations in `web/db/migrations` through a `pg` pool.
 *
 * Drizzle wraps all migrations in one transaction. PostgreSQL forbids
 * CREATE INDEX CONCURRENTLY in a transaction, so each migration runs in its
 * own transaction and concurrent-index migrations run outside one. Production
 * (migrate-planetscale.mjs), CI and local databases (scripts/db-migrate.mjs)
 * all apply migrations through this function.
 */
export async function applyPendingMigrations(pool, webDir) {
  const requireFromWeb = createRequire(path.join(webDir, "package.json"));
  const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
  const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");
  const migrations = readMigrationFiles({ migrationsFolder: path.join(webDir, "db/migrations") });

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
      if (migration.sql.some((statement) => concurrentIndexPattern.test(statement))) {
        await dropInvalidConcurrentIndex(client, migration);
        await recordMigration(client, migration);
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
