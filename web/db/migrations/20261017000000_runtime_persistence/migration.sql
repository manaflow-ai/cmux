-- Replay-safe: every statement here is a no-op where its object already exists, so this migration
-- also applies to a database that has main's Run model and never ran it. On a fresh database it
-- creates exactly what it always created.
DO $$ BEGIN
  CREATE TYPE "cloud_runtime_kind" AS ENUM ('persistent', 'ephemeral');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
  CREATE TYPE "cloud_runtime_lifecycle" AS ENUM ('provisioning', 'ready', 'running', 'draining', 'suspended', 'stopped', 'released', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
-- The backfill runs only when this statement adds lifecycle_state: a replay never rewrites live lifecycle states.
DO $$
DECLARE
  backfill boolean := NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'cloud_runtimes' AND column_name = 'lifecycle_state'
  );
BEGIN
ALTER TABLE "cloud_runtimes"
  ADD COLUMN IF NOT EXISTS "runtime_kind" "cloud_runtime_kind" DEFAULT 'persistent' NOT NULL,
  ADD COLUMN IF NOT EXISTS "lifecycle_state" "cloud_runtime_lifecycle" DEFAULT 'provisioning' NOT NULL,
  ADD COLUMN IF NOT EXISTS "lease_token" text,
  ADD COLUMN IF NOT EXISTS "lease_generation" integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS "lease_expires_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "idempotency_key" text,
  ADD COLUMN IF NOT EXISTS "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  ADD COLUMN IF NOT EXISTS "released_at" timestamp with time zone;
IF NOT backfill THEN
  RETURN;
END IF;
UPDATE "cloud_runtimes" AS runtime
SET "lifecycle_state" = CASE
  WHEN machine."status" = 'running' THEN 'running'::"cloud_runtime_lifecycle"
  WHEN machine."status" = 'paused' THEN 'suspended'::"cloud_runtime_lifecycle"
  WHEN machine."status" = 'provisioning' THEN 'provisioning'::"cloud_runtime_lifecycle"
  WHEN machine."status" = 'failed' THEN 'failed'::"cloud_runtime_lifecycle"
  ELSE 'stopped'::"cloud_runtime_lifecycle"
END,
"released_at" = CASE
  WHEN machine."status" = 'destroyed' THEN coalesce(machine."destroyed_at", runtime."created_at")
  ELSE null
END,
"updated_at" = now()
FROM "cloud_vms" AS machine
WHERE machine."id" = runtime."machine_id";
UPDATE "cloud_runtimes"
SET "lifecycle_state" = 'released',
    "released_at" = coalesce("released_at", "created_at"),
    "updated_at" = now()
WHERE "machine_id" IS NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
IF NOT EXISTS (
  SELECT 1 FROM pg_constraint
  WHERE conname = 'cloud_runtimes_lease_generation_nonnegative' AND conrelid = '"cloud_runtimes"'::regclass
) THEN
ALTER TABLE "cloud_runtimes"
  ADD CONSTRAINT "cloud_runtimes_lease_generation_nonnegative" CHECK ("lease_generation" >= 0);
END IF;
END $$;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_runtimes_owner_lifecycle_idx"
  ON "cloud_runtimes" ("owner_team_id", "lifecycle_state", "updated_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_runtimes_lease_idx"
  ON "cloud_runtimes" ("lifecycle_state", "lease_expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_runtimes_owner_idempotency_unique"
  ON "cloud_runtimes" ("owner_team_id", "idempotency_key")
  WHERE "idempotency_key" IS NOT NULL;--> statement-breakpoint
-- The FK is created only together with the column. main's 20261018110000_durable_team_runs adds
-- run_attempts.runtime_id with no FK, and its rows may point at runtimes that no longer exist, so
-- where the column already exists it is left as it is; the reconcile migration adds the FK there
-- as NOT VALID and validates it after clearing orphans.
DO $$ BEGIN
IF NOT EXISTS (
  SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'run_attempts' AND column_name = 'runtime_id'
) THEN
ALTER TABLE "run_attempts"
  ADD COLUMN "runtime_id" uuid REFERENCES "cloud_runtimes"("id") ON DELETE SET NULL;
END IF;
END $$;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_attempts_runtime_idx"
  ON "run_attempts" ("runtime_id", "created_at", "id");
