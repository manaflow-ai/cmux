-- One Cloud-only access grant owns every Freestyle WireGuard peer for one Mac.
-- This table is separate from the iOS/Iroh device registry.

DO $$ BEGIN
  CREATE TYPE "cloud_vm_tunnel_purpose" AS ENUM ('terminal', 'browser');
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS "cloud_vm_access_grants" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "device_id" text NOT NULL,
  "reported_name" text,
  "display_name" text,
  "model_identifier" text,
  "os_version" text,
  "architecture" text,
  "cmux_version" text,
  "cmux_build" text,
  "cmux_channel" text,
  "stack_session_id" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_control_plane_at" timestamp with time zone DEFAULT now() NOT NULL,
  "revoked_at" timestamp with time zone
);

CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_access_grants_user_device_unique"
  ON "cloud_vm_access_grants" ("user_id", "device_id")
  WHERE "revoked_at" IS NULL;
CREATE INDEX IF NOT EXISTS "cloud_vm_access_grants_user_idx"
  ON "cloud_vm_access_grants" ("user_id");
CREATE INDEX IF NOT EXISTS "cloud_vm_access_grants_session_idx"
  ON "cloud_vm_access_grants" ("user_id", "stack_session_id");

ALTER TABLE "cloud_vm_tunnels"
  ADD COLUMN IF NOT EXISTS "access_grant_id" uuid,
  ADD COLUMN IF NOT EXISTS "tunnel_purpose" "cloud_vm_tunnel_purpose" DEFAULT 'browser';

-- Preserve development databases created by the earlier branch migration.
INSERT INTO "cloud_vm_access_grants" (
  "user_id", "device_id", "reported_name", "created_at", "updated_at", "last_control_plane_at"
)
SELECT DISTINCT ON ("user_id", "device_fingerprint")
  "user_id", "device_fingerprint", "device_name", "created_at", "updated_at",
  COALESCE("last_config_issued_at", "updated_at")
FROM "cloud_vm_tunnels"
WHERE "access_grant_id" IS NULL
ORDER BY "user_id", "device_fingerprint", "created_at" DESC;

UPDATE "cloud_vm_tunnels" AS tunnel
SET "access_grant_id" = grant_row."id"
FROM "cloud_vm_access_grants" AS grant_row
WHERE tunnel."access_grant_id" IS NULL
  AND grant_row."user_id" = tunnel."user_id"
  AND grant_row."device_id" = tunnel."device_fingerprint"
  AND grant_row."revoked_at" IS NULL;

ALTER TABLE "cloud_vm_tunnels"
  ALTER COLUMN "access_grant_id" SET NOT NULL,
  ALTER COLUMN "tunnel_purpose" SET NOT NULL,
  ALTER COLUMN "tunnel_purpose" DROP DEFAULT;

DO $$ BEGIN
  ALTER TABLE "cloud_vm_tunnels"
    ADD CONSTRAINT "cloud_vm_tunnels_access_grant_id_cloud_vm_access_grants_id_fk"
    FOREIGN KEY ("access_grant_id") REFERENCES "cloud_vm_access_grants"("id") ON DELETE cascade;
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

DROP INDEX IF EXISTS "cloud_vm_tunnels_user_device_unique";
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_tunnels_user_device_purpose_unique"
  ON "cloud_vm_tunnels" ("user_id", "device_fingerprint", "tunnel_purpose")
  WHERE "revoked_at" IS NULL;
CREATE INDEX IF NOT EXISTS "cloud_vm_tunnels_access_grant_idx"
  ON "cloud_vm_tunnels" ("access_grant_id");
