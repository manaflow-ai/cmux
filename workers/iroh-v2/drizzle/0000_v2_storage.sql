-- IROH v2 storage schema, version 1.
-- This file is append-only after deployment. Do not edit a shipped migration.
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "team_meta" (
  "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
  "revision" INTEGER NOT NULL DEFAULT 0 CHECK ("revision" >= 0),
  "schema_version" INTEGER NOT NULL DEFAULT 1 CHECK ("schema_version" = 1)
);
--> statement-breakpoint
INSERT OR IGNORE INTO "team_meta" ("id", "revision", "schema_version") VALUES (1, 0, 1);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "devices" (
  "identity_key" TEXT PRIMARY KEY NOT NULL,
  "device_record_id" TEXT NOT NULL,
  "environment" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "team_id" TEXT NOT NULL,
  "user_id" TEXT NOT NULL,
  "device_id" TEXT NOT NULL,
  "app_namespace" TEXT NOT NULL,
  "build_tag" TEXT NOT NULL,
  "endpoint_id" TEXT NOT NULL,
  "identity_generation" INTEGER NOT NULL CHECK ("identity_generation" >= 0),
  "platform" TEXT NOT NULL CHECK ("platform" IN ('mac', 'ios')),
  "display_name" TEXT NOT NULL,
  "app_version" TEXT NOT NULL,
  "pairing_enabled" INTEGER NOT NULL CHECK ("pairing_enabled" IN (0, 1)),
  "capabilities_json" TEXT NOT NULL,
  "relay_urls_json" TEXT NOT NULL,
  "revoked" INTEGER NOT NULL DEFAULT 0 CHECK ("revoked" IN (0, 1)),
  "revision" INTEGER NOT NULL CHECK ("revision" >= 0),
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  CHECK (length("identity_key") BETWEEN 1 AND 2048),
  CHECK (length("capabilities_json") <= 16384),
  CHECK (length("relay_urls_json") <= 65536)
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "devices_endpoint_idx" ON "devices" ("endpoint_id");
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "devices_record_idx" ON "devices" ("device_record_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "devices_user_idx" ON "devices" ("user_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "devices_team_idx" ON "devices" ("team_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "pending_challenges" (
  "identity_key" TEXT PRIMARY KEY NOT NULL,
  "challenge_id" TEXT NOT NULL,
  "nonce_hash" TEXT NOT NULL,
  "payload_hash" TEXT NOT NULL,
  "expires_at" INTEGER NOT NULL,
  "issued_at" INTEGER NOT NULL,
  CHECK ("expires_at" >= "issued_at"),
  CHECK (length("nonce_hash") BETWEEN 1 AND 256),
  CHECK (length("payload_hash") BETWEEN 1 AND 256)
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "pending_challenges_id_idx" ON "pending_challenges" ("challenge_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "registration_receipts" (
  "identity_key" TEXT NOT NULL,
  "request_id" TEXT NOT NULL,
  "request_hash" TEXT NOT NULL,
  "device_json" TEXT NOT NULL,
  "created_at" INTEGER NOT NULL,
  PRIMARY KEY ("identity_key"),
  CHECK (length("device_json") <= 131072)
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "registration_receipts_identity_idx" ON "registration_receipts" ("identity_key");
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "registration_receipts_request_idx" ON "registration_receipts" ("request_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "permissions" (
  "subject_user_id" TEXT NOT NULL,
  "device_record_id" TEXT NOT NULL,
  "connect" INTEGER NOT NULL DEFAULT 0 CHECK ("connect" IN (0, 1)),
  "manage" INTEGER NOT NULL DEFAULT 0 CHECK ("manage" IN (0, 1)),
  "updated_at" INTEGER NOT NULL,
  PRIMARY KEY ("subject_user_id", "device_record_id")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "permissions_device_idx" ON "permissions" ("device_record_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "permissions_subject_idx" ON "permissions" ("subject_user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "user_usage" (
  "scope_key" TEXT NOT NULL,
  "user_id" TEXT NOT NULL,
  "operation" TEXT NOT NULL,
  "tokens" REAL NOT NULL CHECK ("tokens" >= 0),
  "refilled_at" INTEGER NOT NULL,
  "consumed" INTEGER NOT NULL DEFAULT 0 CHECK ("consumed" >= 0),
  PRIMARY KEY ("scope_key", "user_id", "operation")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "user_usage_user_idx" ON "user_usage" ("scope_key", "user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "storage_usage" (
  "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
  "device_count" INTEGER NOT NULL DEFAULT 0 CHECK ("device_count" >= 0),
  "permission_count" INTEGER NOT NULL DEFAULT 0 CHECK ("permission_count" >= 0),
  "metadata_bytes" INTEGER NOT NULL DEFAULT 0 CHECK ("metadata_bytes" >= 0)
);
--> statement-breakpoint
INSERT OR IGNORE INTO "storage_usage" ("id") VALUES (1);
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "devices_usage_insert_guard"
BEFORE INSERT ON "devices"
WHEN (SELECT "device_count" FROM "storage_usage" WHERE "id" = 1) >= 4096
  OR (SELECT "metadata_bytes" FROM "storage_usage" WHERE "id" = 1) + length(NEW."capabilities_json") + length(NEW."relay_urls_json") > 16777216
BEGIN SELECT RAISE(ABORT, 'device_limit'); END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "devices_usage_insert_count"
AFTER INSERT ON "devices"
BEGIN UPDATE "storage_usage" SET "device_count" = "device_count" + 1, "metadata_bytes" = "metadata_bytes" + length(NEW."capabilities_json") + length(NEW."relay_urls_json") WHERE "id" = 1; END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "devices_usage_update_guard"
BEFORE UPDATE OF "capabilities_json", "relay_urls_json" ON "devices"
WHEN (SELECT "metadata_bytes" FROM "storage_usage" WHERE "id" = 1) - length(OLD."capabilities_json") - length(OLD."relay_urls_json") + length(NEW."capabilities_json") + length(NEW."relay_urls_json") > 16777216
BEGIN SELECT RAISE(ABORT, 'storage_limit'); END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "devices_usage_update_bytes"
AFTER UPDATE OF "capabilities_json", "relay_urls_json" ON "devices"
BEGIN UPDATE "storage_usage" SET "metadata_bytes" = "metadata_bytes" - length(OLD."capabilities_json") - length(OLD."relay_urls_json") + length(NEW."capabilities_json") + length(NEW."relay_urls_json") WHERE "id" = 1; END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "permissions_usage_insert_guard"
BEFORE INSERT ON "permissions"
WHEN (SELECT "permission_count" FROM "storage_usage" WHERE "id" = 1) >= 16384
BEGIN SELECT RAISE(ABORT, 'permission_limit'); END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "permissions_usage_insert_count"
AFTER INSERT ON "permissions"
BEGIN UPDATE "storage_usage" SET "permission_count" = "permission_count" + 1 WHERE "id" = 1; END;
--> statement-breakpoint
CREATE TRIGGER IF NOT EXISTS "permissions_usage_delete_count"
AFTER DELETE ON "permissions"
BEGIN UPDATE "storage_usage" SET "permission_count" = max(0, "permission_count" - 1) WHERE "id" = 1; END;
