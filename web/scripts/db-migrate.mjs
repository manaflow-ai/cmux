#!/usr/bin/env node
// Applies pending migrations to DIRECT_DATABASE_URL (or DATABASE_URL) the way
// production does, through cloud-vm/apply-migrations.mjs. `drizzle-kit migrate`
// runs every migration in one transaction, so it cannot apply a migration that
// uses CREATE INDEX CONCURRENTLY.
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applyPendingMigrations } from "./cloud-vm/apply-migrations.mjs";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const connectionString = process.env.DIRECT_DATABASE_URL || process.env.DATABASE_URL;
if (!connectionString) {
  console.error("db-migrate: set DIRECT_DATABASE_URL or DATABASE_URL");
  process.exit(2);
}
const { Pool } = createRequire(path.join(webDir, "package.json"))("pg");
const pool = new Pool({ connectionString });
try {
  const applied = await applyPendingMigrations(pool, webDir);
  console.log(`db-migrate: applied ${applied} pending migration(s)`);
} catch (error) {
  console.error(`db-migrate: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
