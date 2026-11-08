#!/usr/bin/env node

import { createRequire } from "node:module";
import path from "node:path";

const requireFromWeb = createRequire(path.join(process.cwd(), "package.json"));
const { Pool } = requireFromWeb("pg");
const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");

const connectionString = process.env.DIRECT_DATABASE_URL?.trim() || process.env.DATABASE_URL?.trim();
if (!connectionString) {
  throw new Error("DATABASE_URL or DIRECT_DATABASE_URL is required");
}

const pool = new Pool({ connectionString, max: 1 });
const migrations = readMigrationFiles({ migrationsFolder: path.join(process.cwd(), "db/migrations") });

async function applyMigration(client, migration) {
  for (const statement of migration.sql) {
    await client.query(statement);
  }
  await client.query(
    "insert into drizzle.__drizzle_migrations (hash, created_at, name) values ($1, $2, $3)",
    [migration.hash, migration.folderMillis, migration.name ?? null],
  );
}

async function dropInvalidConcurrentIndex(migration) {
  const indexStatement = migration.sql.find((statement) => /CREATE\s+INDEX\s+CONCURRENTLY/i.test(statement));
  const indexName = indexStatement?.match(
    /CREATE\s+INDEX\s+CONCURRENTLY(?:\s+IF\s+NOT\s+EXISTS)?\s+"([^"]+)"/i,
  )?.[1];
  if (!indexName) return;

  const existing = await pool.query(
    `select n.nspname as schema_name, c.relname as index_name, i.indisvalid
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       join pg_index i on i.indexrelid = c.oid
      where c.relname = $1`,
    [indexName],
  );
  const invalid = existing.rows.find((row) => row.indisvalid === false);
  if (!invalid) return;

  const quoteIdentifier = (value) => `"${String(value).replaceAll('"', '""')}"`;
  await pool.query(
    `drop index concurrently if exists ${quoteIdentifier(invalid.schema_name)}.${quoteIdentifier(invalid.index_name)}`,
  );
}

try {
  await pool.query("create schema if not exists drizzle");
  await pool.query(`
    create table if not exists drizzle.__drizzle_migrations (
      id serial primary key,
      hash text not null,
      created_at bigint,
      name text,
      applied_at timestamp with time zone default now()
    )
  `);

  const applied = await pool.query("select id, hash, created_at, name from drizzle.__drizzle_migrations");
  const pending = getMigrationsToRun({ localMigrations: migrations, dbMigrations: applied.rows });
  for (const migration of pending) {
    const concurrent = migration.sql.some((statement) => /CREATE\s+INDEX\s+CONCURRENTLY/i.test(statement));
    if (concurrent) {
      await dropInvalidConcurrentIndex(migration);
      await applyMigration(pool, migration);
      continue;
    }

    const client = await pool.connect();
    try {
      await client.query("begin");
      await applyMigration(client, migration);
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }
} finally {
  await pool.end();
}

