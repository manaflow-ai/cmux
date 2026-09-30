#!/usr/bin/env node
import { createRequire } from "node:module";
import path from "node:path";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";
import { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } from "./planetscale-operator.mjs";

const usage = "Usage: migrate-planetscale.mjs [web-dir] <staging|production> [--check]";
const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
if (rest.some((arg) => arg !== "--check")) {
  console.error(usage);
  process.exit(2);
}
const checkOnly = rest.includes("--check");
try {
  const pool = createPlanetScaleOperatorPool(webDir, loadTargetEnv(project), project.projectName);
  try {
    if (checkOnly) {
      await pool.query("begin read only");
      try {
        await pool.query("select 1");
      } finally {
        await pool.query("rollback");
      }
    } else {
      const requireFromWeb = createRequire(path.join(webDir, "package.json"));
      const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
      const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");
      const migrationsFolder = path.join(webDir, "db/migrations");
      const migrations = readMigrationFiles({ migrationsFolder });

      // Drizzle wraps all migrations in one transaction. PostgreSQL forbids
      // CREATE INDEX CONCURRENTLY in a transaction, so run each migration in
      // its own transaction and leave concurrent-index migrations outside one.
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
      for (const migration of pending) {
        const run = async (client) => {
          for (const statement of migration.sql) await client.query(statement);
          await client.query(
            "insert into drizzle.__drizzle_migrations (hash, created_at, name) values ($1, $2, $3)",
            [migration.hash, migration.folderMillis, migration.name ?? null],
          );
        };
        const concurrent = migration.sql.some((statement) => /CREATE\s+INDEX\s+CONCURRENTLY/i.test(statement));
        if (concurrent) {
          await run(pool);
          continue;
        }
        const client = await pool.connect();
        try {
          await client.query("begin");
          await run(client);
          await client.query("commit");
        } catch (error) {
          await client.query("rollback");
          throw error;
        } finally {
          client.release();
        }
      }
    }
  } finally {
    await pool.end();
  }
  console.log(`${project.label} PlanetScale ${checkOnly ? "connection verified (read only)" : "migration applied"}`);
} catch (error) {
  // Driver errors may contain credentials, SQL, or customer rows.
  console.error(error instanceof PlanetScaleOperatorConfigError ? error.message :
    `${project.label} PlanetScale ${checkOnly ? "connection check" : "migration"} failed; check target credentials, access, and migration state.`);
  process.exitCode = 1;
}
