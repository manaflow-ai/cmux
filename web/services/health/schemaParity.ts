import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";

/**
 * Schema parity: compares the migrations bundled with the deployed code
 * (web/db/migrations/<name>/migration.sql) against the migrations recorded as
 * applied in the database.
 *
 * drizzle-orm's node-postgres migrator (used by scripts/migrate-aws-rds-iam.ts
 * and scripts/cloud-vm/migrate-vercel-aurora-iam.mjs) records applied
 * migrations in "drizzle"."__drizzle_migrations"
 * (id, hash, created_at bigint millis, name, applied_at). Pending migrations
 * are folder names absent from that table's "name" column; legacy rows written
 * before the "name" column existed are matched by folder-timestamp millis,
 * then by sql hash, mirroring drizzle's own upgrade matching.
 */

export const DRIZZLE_MIGRATIONS_SCHEMA = "drizzle";
export const DRIZZLE_MIGRATIONS_TABLE = "__drizzle_migrations";

export type AppliedMigrationRow = {
  readonly name: string | null;
  readonly hash: string | null;
  readonly createdAt: string | number | bigint | null;
};

export type SchemaParityStatus = "ok" | "ahead" | "behind";

export type SchemaParityReport = {
  /** ok = heads equal; ahead = db has migrations this build does not know
   * about (normal migrate-then-deploy window); behind = db lags the code. */
  readonly status: SchemaParityStatus;
  readonly codeHead: string | null;
  readonly dbHead: string | null;
  /** Bundled migration names not yet applied to the database, oldest first. */
  readonly pending: readonly string[];
};

export function defaultMigrationsDir(): string {
  // Same convention as app/lib/open-graph-image.tsx: runtime files resolved
  // from the web project root and pinned into the serverless bundle via
  // outputFileTracingIncludes in next.config.ts.
  return join(process.cwd(), "db", "migrations");
}

/** Migration folder names bundled with this build, sorted oldest first. */
export function listBundledMigrations(dir: string = defaultMigrationsDir()): string[] {
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(join(dir, entry.name, "migration.sql")))
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b));
}

/** sha256 of each bundled migration.sql, keyed by folder name (drizzle's hash). */
export function bundledMigrationHashes(
  names: readonly string[],
  dir: string = defaultMigrationsDir(),
): Map<string, string> {
  const hashes = new Map<string, string>();
  for (const name of names) {
    const contents = readFileSync(join(dir, name, "migration.sql"), "utf8");
    hashes.set(name, createHash("sha256").update(contents).digest("hex"));
  }
  return hashes;
}

/** UTC millis encoded in a migration folder's 14-digit timestamp prefix. */
export function migrationFolderMillis(name: string): number | null {
  const stamp = name.slice(0, 14);
  if (!/^\d{14}$/.test(stamp)) return null;
  return Date.UTC(
    Number(stamp.slice(0, 4)),
    Number(stamp.slice(4, 6)) - 1,
    Number(stamp.slice(6, 8)),
    Number(stamp.slice(8, 10)),
    Number(stamp.slice(10, 12)),
    Number(stamp.slice(12, 14)),
  );
}

/** created_at truncated to whole seconds, as drizzle's upgrade matcher does. */
function rowMillis(createdAt: AppliedMigrationRow["createdAt"]): number | null {
  if (createdAt === null || createdAt === undefined) return null;
  const stringified = String(createdAt);
  if (!/^\d+$/.test(stringified) || stringified.length <= 3) return null;
  return Number(stringified.substring(0, stringified.length - 3) + "000");
}

export function compareSchemaParity(
  codeMigrations: readonly string[],
  appliedRows: readonly AppliedMigrationRow[],
  hashByName?: ReadonlyMap<string, string>,
): SchemaParityReport {
  const code = [...codeMigrations].sort((a, b) => a.localeCompare(b));

  const byMillis = new Map<number, string[]>();
  for (const name of code) {
    const millis = migrationFolderMillis(name);
    if (millis === null) continue;
    const bucket = byMillis.get(millis);
    if (bucket) bucket.push(name);
    else byMillis.set(millis, [name]);
  }
  const byHash = new Map<string, string>();
  if (hashByName) {
    for (const [name, hash] of hashByName) byHash.set(hash, name);
  }

  const applied = new Set<string>();
  for (const row of appliedRows) {
    if (row.name) {
      applied.add(row.name);
      continue;
    }
    // Legacy row from before drizzle recorded names: resolve like drizzle's
    // migrations-table upgrade does (folder millis, then hash on collision).
    const millis = rowMillis(row.createdAt);
    const candidates = millis === null ? undefined : byMillis.get(millis);
    if (candidates?.length === 1) {
      applied.add(candidates[0]!);
    } else {
      const matched = row.hash ? byHash.get(row.hash) : undefined;
      if (matched) applied.add(matched);
    }
  }

  const pending = code.filter((name) => !applied.has(name));
  const codeSet = new Set(code);
  const dbOnly = [...applied].filter((name) => !codeSet.has(name));
  const dbHead = applied.size > 0 ? [...applied].sort((a, b) => a.localeCompare(b)).at(-1)! : null;

  return {
    status: pending.length > 0 ? "behind" : dbOnly.length > 0 ? "ahead" : "ok",
    codeHead: code.at(-1) ?? null,
    dbHead,
    pending,
  };
}

function isMissingMigrationsTable(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; depth < 5 && current; depth++) {
    if (typeof current === "object" && "code" in current && (current as { code?: unknown }).code === "42P01") {
      return true;
    }
    current = typeof current === "object" && current !== null && "cause" in current
      ? (current as { cause?: unknown }).cause
      : undefined;
  }
  return false;
}

async function appliedMigrations(): Promise<AppliedMigrationRow[]> {
  try {
    const result = await cloudDb().execute(sql`
      select "name", "hash", "created_at" as "createdAt"
      from ${sql.identifier(DRIZZLE_MIGRATIONS_SCHEMA)}.${sql.identifier(DRIZZLE_MIGRATIONS_TABLE)}
    `);
    return databaseRows(result).map((row) => ({
      name: typeof row.name === "string" ? row.name : null,
      hash: typeof row.hash === "string" ? row.hash : null,
      createdAt: (row.createdAt ?? null) as AppliedMigrationRow["createdAt"],
    }));
  } catch (error) {
    // A database that was never migrated has no drizzle bookkeeping table;
    // report every bundled migration as pending instead of erroring.
    if (isMissingMigrationsTable(error)) return [];
    throw error;
  }
}

function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as readonly Record<string, unknown>[];
  const rows = (result as { readonly rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? (rows as readonly Record<string, unknown>[]) : [];
}

export async function schemaParityReport(): Promise<SchemaParityReport> {
  const code = listBundledMigrations();
  const rows = await appliedMigrations();
  // Hashes are only needed to disambiguate legacy nameless rows.
  const hashByName = rows.some((row) => !row.name) ? bundledMigrationHashes(code) : undefined;
  return compareSchemaParity(code, rows, hashByName);
}
