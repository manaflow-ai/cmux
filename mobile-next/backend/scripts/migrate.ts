// Applies migrations/*.sql in order with the PlanetScale fetch driver.
// Usage: DATABASE_HOST=... DATABASE_USERNAME=... DATABASE_PASSWORD=... bun scripts/migrate.ts
// Use an admin-role password (DDL); the Worker's own password is readwriter.
import { connect } from "@planetscale/database";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const { DATABASE_HOST: host, DATABASE_USERNAME: username, DATABASE_PASSWORD: password } = process.env;
if (!host || !username || !password) {
  console.error("set DATABASE_HOST, DATABASE_USERNAME, DATABASE_PASSWORD");
  process.exit(2);
}
const conn = connect({ host, username, password });
const dir = join(import.meta.dir, "..", "migrations");

await conn.execute(
  "CREATE TABLE IF NOT EXISTS schema_migrations (name VARCHAR(255) NOT NULL PRIMARY KEY, applied_at DATETIME(3) NOT NULL)",
);
const applied = new Set(
  ((await conn.execute("SELECT name FROM schema_migrations")).rows as { name: string }[]).map((r) => r.name),
);

for (const file of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
  if (applied.has(file)) {
    console.log(`skip ${file}`);
    continue;
  }
  const sql = readFileSync(join(dir, file), "utf8")
    .split("\n")
    .map((l) => l.replace(/--.*$/, ""))
    .join("\n");
  for (const stmt of sql.split(";").map((s) => s.trim()).filter(Boolean)) await conn.execute(stmt);
  await conn.execute(
    `INSERT INTO schema_migrations (name, applied_at) VALUES ('${file.replace(/'/g, "")}', UTC_TIMESTAMP(3))`,
  );
  console.log(`applied ${file}`);
}
