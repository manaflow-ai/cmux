#!/usr/bin/env bun
// Applies every web/db/clickhouse/*.sql file, in name order, to one ClickHouse
// database with the admin credential. `{db}` in each file becomes the target
// database. Every statement is `IF NOT EXISTS`, so reruns are no-ops.
//
//   bun scripts/clickhouse-migrate.ts coderouter_dev
//   bun scripts/clickhouse-migrate.ts coderouter
//
// Requires CLICKHOUSE_ADMIN_URL, CLICKHOUSE_ADMIN_USER, and
// CLICKHOUSE_ADMIN_PASSWORD (source ~/.secrets/clickhouse.env). The app's
// CLICKHOUSE_* credential holds SELECT and INSERT only and is never used here.
import { readdir, readFile } from "node:fs/promises";

const DATABASE_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const STATEMENT_TIMEOUT_MS = 30_000;

const [database, ...extra] = process.argv.slice(2);
if (!database || extra.length > 0 || !DATABASE_PATTERN.test(database)) {
  console.error("Usage: bun scripts/clickhouse-migrate.ts <database>");
  process.exit(2);
}

const adminUrl = process.env.CLICKHOUSE_ADMIN_URL?.trim();
const adminUser = process.env.CLICKHOUSE_ADMIN_USER?.trim();
const adminPassword = process.env.CLICKHOUSE_ADMIN_PASSWORD?.trim();
if (!adminUrl || !adminUser || !adminPassword) {
  console.error(
    "CLICKHOUSE_ADMIN_URL, CLICKHOUSE_ADMIN_USER, and CLICKHOUSE_ADMIN_PASSWORD are required. " +
      "Source ~/.secrets/clickhouse.env. The runtime CLICKHOUSE_* credential cannot run DDL.",
  );
  process.exit(2);
}

const endpoint = new URL(adminUrl);
const authorization = `Basic ${
  Buffer.from(`${adminUser}:${adminPassword}`, "utf8").toString("base64")
}`;
const schemaDirectory = new URL("../db/clickhouse/", import.meta.url);
const files = (await readdir(schemaDirectory))
  .filter((name) => name.endsWith(".sql"))
  .sort();
if (files.length === 0) {
  console.error("No .sql files found under web/db/clickhouse.");
  process.exit(1);
}

let applied = 0;
for (const file of files) {
  const source = await readFile(new URL(file, schemaDirectory), "utf8");
  const statements = splitStatements(source.replaceAll("{db}", database));
  for (const [index, statement] of statements.entries()) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { authorization, "content-type": "text/plain; charset=utf-8" },
      body: statement,
      signal: AbortSignal.timeout(STATEMENT_TIMEOUT_MS),
    });
    if (!response.ok) {
      // DDL carries no secrets, so the server's error text is safe to print.
      const detail = (await response.text()).slice(0, 500);
      console.error(
        `${file} statement ${index + 1}/${statements.length} failed with status ${response.status}: ${detail}`,
      );
      process.exit(1);
    }
    applied++;
  }
  console.log(`${file}: ${statements.length} statements applied to ${database}`);
}
console.log(`Applied ${applied} statements from ${files.length} files to ${database}.`);

/** Drops `--` comment lines and splits on `;`. The schema has no string literals containing `;`. */
function splitStatements(sql: string): string[] {
  return sql
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("--"))
    .join("\n")
    .split(";")
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}
