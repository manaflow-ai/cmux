CREATE TABLE IF NOT EXISTS "cloud_vm_bases" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "scope_type" text NOT NULL,
  "scope_id" text NOT NULL,
  "name" text DEFAULT 'base' NOT NULL,
  "active_generation" integer DEFAULT 0 NOT NULL,
  "active_vm_id" uuid,
  "active_provider" "vm_provider",
  "active_provider_vm_id" text,
  "state" text DEFAULT 'creating' NOT NULL,
  "created_by_user_id" text NOT NULL,
  "last_opened_by_user_id" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "cloud_vm_base_generations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "base_id" uuid NOT NULL,
  "generation" integer NOT NULL,
  "vm_id" uuid,
  "provider" "vm_provider",
  "provider_vm_id" text,
  "state" text DEFAULT 'creating' NOT NULL,
  "created_by_user_id" text NOT NULL,
  "retained_at" timestamp with time zone,
  "deleted_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "cloud_vm_base_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "base_id" uuid NOT NULL,
  "user_id" text NOT NULL,
  "event_type" text NOT NULL,
  "old_generation" integer,
  "new_generation" integer,
  "old_vm_id" uuid,
  "new_vm_id" uuid,
  "old_provider_vm_id" text,
  "new_provider_vm_id" text,
  "reason" text,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_bases"
    ADD CONSTRAINT "cloud_vm_bases_active_vm_id_cloud_vms_id_fk"
    FOREIGN KEY ("active_vm_id") REFERENCES "cloud_vms"("id") ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_base_generations"
    ADD CONSTRAINT "cloud_vm_base_generations_base_id_cloud_vm_bases_id_fk"
    FOREIGN KEY ("base_id") REFERENCES "cloud_vm_bases"("id") ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_base_generations"
    ADD CONSTRAINT "cloud_vm_base_generations_vm_id_cloud_vms_id_fk"
    FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id") ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_base_events"
    ADD CONSTRAINT "cloud_vm_base_events_base_id_cloud_vm_bases_id_fk"
    FOREIGN KEY ("base_id") REFERENCES "cloud_vm_bases"("id") ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_base_events"
    ADD CONSTRAINT "cloud_vm_base_events_old_vm_id_cloud_vms_id_fk"
    FOREIGN KEY ("old_vm_id") REFERENCES "cloud_vms"("id") ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

DO $$ BEGIN
  ALTER TABLE "cloud_vm_base_events"
    ADD CONSTRAINT "cloud_vm_base_events_new_vm_id_cloud_vms_id_fk"
    FOREIGN KEY ("new_vm_id") REFERENCES "cloud_vms"("id") ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_bases_scope_name_unique"
  ON "cloud_vm_bases" ("scope_type","scope_id","name");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_bases_active_vm_idx"
  ON "cloud_vm_bases" ("active_vm_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_bases_provider_vm_idx"
  ON "cloud_vm_bases" ("active_provider","active_provider_vm_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_base_generations_base_generation_unique"
  ON "cloud_vm_base_generations" ("base_id","generation");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_base_generations_vm_idx"
  ON "cloud_vm_base_generations" ("vm_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_base_generations_provider_vm_idx"
  ON "cloud_vm_base_generations" ("provider","provider_vm_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_base_events_base_created_idx"
  ON "cloud_vm_base_events" ("base_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_base_events_user_created_idx"
  ON "cloud_vm_base_events" ("user_id","created_at");--> statement-breakpoint

WITH candidates AS (
  SELECT DISTINCT ON (
    CASE WHEN "billing_team_id" = "user_id" THEN 'user' ELSE 'team' END,
    "billing_team_id"
  )
    "id",
    "user_id",
    "billing_team_id",
    CASE WHEN "billing_team_id" = "user_id" THEN 'user' ELSE 'team' END AS "scope_type",
    "provider",
    "provider_vm_id",
    "status",
    "created_at"
  FROM "cloud_vms"
  WHERE "idempotency_key" = 'cmux-default-freestyle-sshd-v1'
    AND "billing_team_id" IS NOT NULL
    AND "status" != 'destroyed'
  ORDER BY
    CASE WHEN "billing_team_id" = "user_id" THEN 'user' ELSE 'team' END,
    "billing_team_id",
    "created_at" DESC
),
inserted_bases AS (
  INSERT INTO "cloud_vm_bases" (
    "scope_type",
    "scope_id",
    "name",
    "active_generation",
    "active_vm_id",
    "active_provider",
    "active_provider_vm_id",
    "state",
    "created_by_user_id",
    "last_opened_by_user_id",
    "created_at",
    "updated_at"
  )
  SELECT
    "scope_type",
    "billing_team_id",
    'base',
    1,
    "id",
    "provider",
    "provider_vm_id",
    CASE WHEN "provider_vm_id" IS NULL THEN 'creating' ELSE 'ready' END,
    "user_id",
    "user_id",
    "created_at",
    now()
  FROM candidates
  ON CONFLICT ("scope_type","scope_id","name") DO NOTHING
  RETURNING "id", "scope_type", "scope_id"
)
INSERT INTO "cloud_vm_base_generations" (
  "base_id",
  "generation",
  "vm_id",
  "provider",
  "provider_vm_id",
  "state",
  "created_by_user_id",
  "created_at",
  "updated_at"
)
SELECT
  inserted_bases."id",
  1,
  candidates."id",
  candidates."provider",
  candidates."provider_vm_id",
  CASE WHEN candidates."provider_vm_id" IS NULL THEN 'creating' ELSE 'active' END,
  candidates."user_id",
  candidates."created_at",
  now()
FROM inserted_bases
JOIN candidates
  ON candidates."scope_type" = inserted_bases."scope_type"
 AND candidates."billing_team_id" = inserted_bases."scope_id"
ON CONFLICT ("base_id","generation") DO NOTHING;
