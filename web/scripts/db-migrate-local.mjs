// Dogfood-only stand-in for the dev-backend entrypoint (not for merge).
// Mirrors web/scripts/cloud-vm/migrate-planetscale.mjs: each migration in its own
// transaction, CREATE INDEX CONCURRENTLY migrations outside one. Prints names only.
import { createRequire } from "node:module";

const require = createRequire(`${process.cwd()}/package.json`);
const { readMigrationFiles } = require("drizzle-orm/migrator");
const { getMigrationsToRun } = require("drizzle-orm/migrator.utils");
const { Pool } = require("pg");

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
try {
  const migrations = readMigrationFiles({ migrationsFolder: `${process.cwd()}/db/migrations` });
  await pool.query("CREATE SCHEMA IF NOT EXISTS drizzle");
  await pool.query(`
    CREATE TABLE IF NOT EXISTS drizzle.__drizzle_migrations (
      id SERIAL PRIMARY KEY,
      hash text NOT NULL,
      created_at bigint,
      name text,
      applied_at timestamp with time zone DEFAULT now()
    )
  `);
  const applied = await pool.query("select id, hash, created_at, name from drizzle.__drizzle_migrations");
  const pending = getMigrationsToRun({ localMigrations: migrations, dbMigrations: applied.rows });
  console.log(`pending migrations: ${pending.length}`);
  const client = await pool.connect();
  try {
    for (const migration of pending) {
      const concurrent = migration.sql.some((statement) => /CREATE\s+INDEX\s+CONCURRENTLY/i.test(statement));
      if (!concurrent) await client.query("begin");
      try {
        for (const statement of migration.sql) await client.query(statement);
        await client.query(
          "insert into drizzle.__drizzle_migrations (hash, created_at, name) values ($1, $2, $3)",
          [migration.hash, migration.folderMillis, migration.name ?? null],
        );
        if (!concurrent) await client.query("commit");
      } catch (error) {
        if (!concurrent) await client.query("rollback");
        throw error;
      }
      console.log(`applied ${migration.name ?? migration.folderMillis}${concurrent ? " (outside a transaction)" : ""}`);
    }
  } finally {
    client.release();
  }
} catch (error) {
  console.error(`migration failed: ${error?.message ?? error}`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
