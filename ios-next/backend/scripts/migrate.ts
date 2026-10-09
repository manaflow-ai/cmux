/**
 * Applies backend/migrations/*.sql to PlanetScale, in order, once each.
 *
 *   DATABASE_HOST=... DATABASE_USERNAME=... DATABASE_PASSWORD=... npx tsx scripts/migrate.ts
 *   npx tsx scripts/migrate.ts --dry-run   # parse and list, no connection
 *
 * Applied versions are recorded in `schema_migrations`. Statements use
 * IF NOT EXISTS, so re-running a partially applied file is safe.
 */
import { connect } from "@planetscale/database";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { format } from "sql-escaper";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "migrations");
const dryRun = process.argv.includes("--dry-run");

export function splitStatements(sql: string): string[] {
  return sql
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .split(/;\s*(?:\n|$)/)
    .map((s) => s.trim())
    .filter(Boolean);
}

const files = readdirSync(dir)
  .filter((f) => /^\d+_.+\.sql$/.test(f))
  .sort();

if (dryRun) {
  for (const f of files) {
    const statements = splitStatements(readFileSync(join(dir, f), "utf8"));
    console.log(`${f}: ${statements.length} statements`);
  }
  process.exit(0);
}

const { DATABASE_HOST, DATABASE_USERNAME, DATABASE_PASSWORD } = process.env;
if (!DATABASE_HOST || !DATABASE_USERNAME || !DATABASE_PASSWORD) {
  console.error("Set DATABASE_HOST, DATABASE_USERNAME and DATABASE_PASSWORD.");
  process.exit(2);
}

const db = connect({ host: DATABASE_HOST, username: DATABASE_USERNAME, password: DATABASE_PASSWORD });

await db.execute(
  "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(255) NOT NULL, applied_at BIGINT NOT NULL, PRIMARY KEY (version))",
);
const applied = new Set((await db.execute("SELECT version FROM schema_migrations")).rows.map((r) => String((r as { version: string }).version)));

let count = 0;
for (const f of files) {
  if (applied.has(f)) continue;
  const statements = splitStatements(readFileSync(join(dir, f), "utf8"));
  for (const stmt of statements) await db.execute(stmt);
  await db.execute(format("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", [f, Date.now()]));
  console.log(`applied ${f} (${statements.length} statements)`);
  count++;
}
console.log(count === 0 ? "database is up to date" : `applied ${count} migration(s)`);
