import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/durable-sqlite";
import type { DurableObjectStorage } from "@cloudflare/workers-types";
import { storageSchema } from "./schema";

/**
 * Runtime migrations are deliberately explicit. The SQL files in drizzle/ are
 * the source for generation and review; this manifest is the immutable runtime
 * copy loaded by the Worker bundle.
 */
export const STORAGE_SCHEMA_VERSION = 3;
export const STORAGE_MIGRATION_HASH = "iroh-v2-storage-0002-20260911-audit-preferences";
const BASE_MIGRATION_HASH = "iroh-v2-storage-0000-20260911-receipt-per-identity";
const PROOF_MIGRATION_HASH = "iroh-v2-storage-0001-20260911-proof-ring";

const statements = [
  `CREATE TABLE IF NOT EXISTS "schema_history" ("version" INTEGER PRIMARY KEY NOT NULL, "hash" TEXT NOT NULL, "applied_at" INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS "team_meta" ("id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1), "revision" INTEGER NOT NULL DEFAULT 0 CHECK ("revision" >= 0), "schema_version" INTEGER NOT NULL DEFAULT 1 CHECK ("schema_version" = 1))`,
  `INSERT OR IGNORE INTO "team_meta" ("id", "revision", "schema_version") VALUES (1, 0, 1)`,
  `CREATE TABLE IF NOT EXISTS "devices" ("identity_key" TEXT PRIMARY KEY NOT NULL, "device_record_id" TEXT NOT NULL, "environment" TEXT NOT NULL, "project_id" TEXT NOT NULL, "team_id" TEXT NOT NULL, "user_id" TEXT NOT NULL, "device_id" TEXT NOT NULL, "app_namespace" TEXT NOT NULL, "build_tag" TEXT NOT NULL, "endpoint_id" TEXT NOT NULL, "identity_generation" INTEGER NOT NULL CHECK ("identity_generation" >= 0), "platform" TEXT NOT NULL CHECK ("platform" IN ('mac', 'ios')), "display_name" TEXT NOT NULL, "app_version" TEXT NOT NULL, "pairing_enabled" INTEGER NOT NULL CHECK ("pairing_enabled" IN (0, 1)), "capabilities_json" TEXT NOT NULL, "relay_urls_json" TEXT NOT NULL, "revoked" INTEGER NOT NULL DEFAULT 0 CHECK ("revoked" IN (0, 1)), "revision" INTEGER NOT NULL CHECK ("revision" >= 0), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, CHECK (length("identity_key") BETWEEN 1 AND 2048), CHECK (length("capabilities_json") <= 16384), CHECK (length("relay_urls_json") <= 65536))`,
  `CREATE UNIQUE INDEX IF NOT EXISTS "devices_endpoint_idx" ON "devices" ("endpoint_id")`,
  `CREATE UNIQUE INDEX IF NOT EXISTS "devices_record_idx" ON "devices" ("device_record_id")`,
  `CREATE INDEX IF NOT EXISTS "devices_user_idx" ON "devices" ("user_id")`,
  `CREATE INDEX IF NOT EXISTS "devices_team_idx" ON "devices" ("team_id")`,
  `CREATE TABLE IF NOT EXISTS "pending_challenges" ("identity_key" TEXT PRIMARY KEY NOT NULL, "challenge_id" TEXT NOT NULL, "nonce_hash" TEXT NOT NULL, "payload_hash" TEXT NOT NULL, "expires_at" INTEGER NOT NULL, "issued_at" INTEGER NOT NULL, CHECK ("expires_at" >= "issued_at"), CHECK (length("nonce_hash") BETWEEN 1 AND 256), CHECK (length("payload_hash") BETWEEN 1 AND 256))`,
  `CREATE UNIQUE INDEX IF NOT EXISTS "pending_challenges_id_idx" ON "pending_challenges" ("challenge_id")`,
  `CREATE TABLE IF NOT EXISTS "registration_receipts" ("identity_key" TEXT PRIMARY KEY NOT NULL, "request_id" TEXT NOT NULL, "request_hash" TEXT NOT NULL, "device_json" TEXT NOT NULL, "created_at" INTEGER NOT NULL, CHECK (length("device_json") <= 131072))`,
  `CREATE INDEX IF NOT EXISTS "registration_receipts_identity_idx" ON "registration_receipts" ("identity_key")`,
  `CREATE UNIQUE INDEX IF NOT EXISTS "registration_receipts_request_idx" ON "registration_receipts" ("request_id")`,
  `CREATE TABLE IF NOT EXISTS "permissions" ("subject_user_id" TEXT NOT NULL, "device_record_id" TEXT NOT NULL, "connect" INTEGER NOT NULL DEFAULT 0 CHECK ("connect" IN (0, 1)), "manage" INTEGER NOT NULL DEFAULT 0 CHECK ("manage" IN (0, 1)), "updated_at" INTEGER NOT NULL, PRIMARY KEY ("subject_user_id", "device_record_id"))`,
  `CREATE INDEX IF NOT EXISTS "permissions_device_idx" ON "permissions" ("device_record_id")`,
  `CREATE INDEX IF NOT EXISTS "permissions_subject_idx" ON "permissions" ("subject_user_id")`,
  `CREATE TABLE IF NOT EXISTS "user_usage" ("scope_key" TEXT NOT NULL, "user_id" TEXT NOT NULL, "operation" TEXT NOT NULL, "tokens" REAL NOT NULL CHECK ("tokens" >= 0), "refilled_at" INTEGER NOT NULL, "consumed" INTEGER NOT NULL DEFAULT 0 CHECK ("consumed" >= 0), PRIMARY KEY ("scope_key", "user_id", "operation"))`,
  `CREATE INDEX IF NOT EXISTS "user_usage_user_idx" ON "user_usage" ("scope_key", "user_id")`,
  `CREATE TABLE IF NOT EXISTS "storage_usage" ("id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1), "device_count" INTEGER NOT NULL DEFAULT 0 CHECK ("device_count" >= 0), "permission_count" INTEGER NOT NULL DEFAULT 0 CHECK ("permission_count" >= 0), "metadata_bytes" INTEGER NOT NULL DEFAULT 0 CHECK ("metadata_bytes" >= 0))`,
  `INSERT OR IGNORE INTO "storage_usage" ("id") VALUES (1)`,
  `CREATE TRIGGER IF NOT EXISTS "devices_usage_insert_guard" BEFORE INSERT ON "devices" WHEN (SELECT "device_count" FROM "storage_usage" WHERE "id" = 1) >= 4096 OR (SELECT "metadata_bytes" FROM "storage_usage" WHERE "id" = 1) + length(NEW."capabilities_json") + length(NEW."relay_urls_json") > 16777216 BEGIN SELECT RAISE(ABORT, 'device_limit'); END`,
  `CREATE TRIGGER IF NOT EXISTS "devices_usage_insert_count" AFTER INSERT ON "devices" BEGIN UPDATE "storage_usage" SET "device_count" = "device_count" + 1, "metadata_bytes" = "metadata_bytes" + length(NEW."capabilities_json") + length(NEW."relay_urls_json") WHERE "id" = 1; END`,
  `CREATE TRIGGER IF NOT EXISTS "devices_usage_update_guard" BEFORE UPDATE OF "capabilities_json", "relay_urls_json" ON "devices" WHEN (SELECT "metadata_bytes" FROM "storage_usage" WHERE "id" = 1) - length(OLD."capabilities_json") - length(OLD."relay_urls_json") + length(NEW."capabilities_json") + length(NEW."relay_urls_json") > 16777216 BEGIN SELECT RAISE(ABORT, 'storage_limit'); END`,
  `CREATE TRIGGER IF NOT EXISTS "devices_usage_update_bytes" AFTER UPDATE OF "capabilities_json", "relay_urls_json" ON "devices" BEGIN UPDATE "storage_usage" SET "metadata_bytes" = "metadata_bytes" - length(OLD."capabilities_json") - length(OLD."relay_urls_json") + length(NEW."capabilities_json") + length(NEW."relay_urls_json") WHERE "id" = 1; END`,
  `CREATE TRIGGER IF NOT EXISTS "permissions_usage_insert_guard" BEFORE INSERT ON "permissions" WHEN (SELECT "permission_count" FROM "storage_usage" WHERE "id" = 1) >= 16384 BEGIN SELECT RAISE(ABORT, 'permission_limit'); END`,
  `CREATE TRIGGER IF NOT EXISTS "permissions_usage_insert_count" AFTER INSERT ON "permissions" BEGIN UPDATE "storage_usage" SET "permission_count" = "permission_count" + 1 WHERE "id" = 1; END`,
  `CREATE TRIGGER IF NOT EXISTS "permissions_usage_delete_count" AFTER DELETE ON "permissions" BEGIN UPDATE "storage_usage" SET "permission_count" = max(0, "permission_count" - 1) WHERE "id" = 1; END`,
];

const proofRingStatements = [
  `CREATE TABLE IF NOT EXISTS "device_proof_replays" ("identity_key" TEXT NOT NULL, "request_id" TEXT NOT NULL, "issued_at" INTEGER NOT NULL, "expires_at" INTEGER NOT NULL, PRIMARY KEY ("identity_key", "request_id"))`,
  `CREATE INDEX IF NOT EXISTS "device_proof_replays_expiry_idx" ON "device_proof_replays" ("identity_key", "expires_at")`,
];
const authorityStatements = [
  `CREATE TABLE IF NOT EXISTS "team_preferences" ("id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1), "relay_urls_json" TEXT NOT NULL, "revision" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS "authority_audit" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "event_type" TEXT NOT NULL, "actor_user_id" TEXT NOT NULL, "target_id" TEXT NOT NULL, "revision" INTEGER NOT NULL, "created_at" INTEGER NOT NULL, "detail_json" TEXT NOT NULL CHECK (length("detail_json") <= 16384))`,
  `CREATE INDEX IF NOT EXISTS "authority_audit_target_idx" ON "authority_audit" ("target_id", "created_at")`,
];

export function applyStorageMigrations(storage: DurableObjectStorage, now = Date.now()): void {
  const db = drizzle(storage, { schema: storageSchema });
  storage.transactionSync(() => {
    db.run(sql.raw(statements[0]!));
    let rows = db.all<{ version: number; hash: string }>(sql`SELECT "version", "hash" FROM "schema_history" ORDER BY "version"`);
    let expectedVersion = 1;
    for (const row of rows) {
      if (row.version !== expectedVersion || row.version > STORAGE_SCHEMA_VERSION) throw new Error("iroh_v2_unsupported_schema_history");
      expectedVersion += 1;
    }
    const apply = (version: number, hash: string, migrationStatements: string[]) => {
      const existing = rows.find((row) => row.version === version);
      if (existing && existing.hash !== hash) throw new Error("iroh_v2_schema_migration_hash_mismatch");
      if (existing) return;
      for (const statement of migrationStatements) db.run(sql.raw(statement));
      db.run(sql`INSERT INTO "schema_history" ("version", "hash", "applied_at") VALUES (${version}, ${hash}, ${now})`);
      rows = [...rows, { version, hash }];
    };
    apply(1, BASE_MIGRATION_HASH, statements.slice(1));
    apply(2, PROOF_MIGRATION_HASH, proofRingStatements);
    apply(3, STORAGE_MIGRATION_HASH, authorityStatements);
  });
}
