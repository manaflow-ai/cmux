CREATE TYPE "cloud_runtime_kind" AS ENUM ('persistent', 'ephemeral');--> statement-breakpoint
CREATE TYPE "cloud_runtime_lifecycle" AS ENUM ('provisioning', 'ready', 'running', 'draining', 'suspended', 'stopped', 'released', 'failed');--> statement-breakpoint
ALTER TABLE "cloud_runtimes"
  ADD COLUMN "runtime_kind" "cloud_runtime_kind" DEFAULT 'persistent' NOT NULL,
  ADD COLUMN "lifecycle_state" "cloud_runtime_lifecycle" DEFAULT 'provisioning' NOT NULL,
  ADD COLUMN "lease_token" text,
  ADD COLUMN "lease_generation" integer DEFAULT 0 NOT NULL,
  ADD COLUMN "lease_expires_at" timestamp with time zone,
  ADD COLUMN "idempotency_key" text,
  ADD COLUMN "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  ADD COLUMN "released_at" timestamp with time zone;--> statement-breakpoint
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
WHERE machine."id" = runtime."machine_id";--> statement-breakpoint
UPDATE "cloud_runtimes"
SET "lifecycle_state" = 'released',
    "released_at" = coalesce("released_at", "created_at"),
    "updated_at" = now()
WHERE "machine_id" IS NULL;--> statement-breakpoint
ALTER TABLE "cloud_runtimes"
  ADD CONSTRAINT "cloud_runtimes_lease_generation_nonnegative" CHECK ("lease_generation" >= 0);--> statement-breakpoint
CREATE INDEX "cloud_runtimes_owner_lifecycle_idx"
  ON "cloud_runtimes" ("owner_team_id", "lifecycle_state", "updated_at");--> statement-breakpoint
CREATE INDEX "cloud_runtimes_lease_idx"
  ON "cloud_runtimes" ("lifecycle_state", "lease_expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_runtimes_owner_idempotency_unique"
  ON "cloud_runtimes" ("owner_team_id", "idempotency_key")
  WHERE "idempotency_key" IS NOT NULL;--> statement-breakpoint
ALTER TABLE "run_attempts"
  ADD COLUMN "runtime_id" uuid REFERENCES "cloud_runtimes"("id") ON DELETE SET NULL;--> statement-breakpoint
CREATE INDEX "run_attempts_runtime_idx"
  ON "run_attempts" ("runtime_id", "created_at", "id");
