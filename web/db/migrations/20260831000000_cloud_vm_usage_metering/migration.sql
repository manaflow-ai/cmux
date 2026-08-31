CREATE TABLE IF NOT EXISTS "cloud_vm_state_transitions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "vm_id" uuid NOT NULL,
  "billing_team_id" text NOT NULL,
  "from_state" text NOT NULL,
  "to_state" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  ALTER TABLE "cloud_vm_state_transitions"
    ADD CONSTRAINT "cloud_vm_state_transitions_vm_id_cloud_vms_id_fk"
    FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id")
    ON DELETE CASCADE ON UPDATE NO ACTION;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Existing rows have no transition history. Establish a non-retroactive
-- baseline so a running VM starts accruing usage when this ledger is applied,
-- while unknown time before the migration is never billed.
INSERT INTO "cloud_vm_state_transitions" (
  "vm_id",
  "billing_team_id",
  "from_state",
  "to_state",
  "created_at"
)
SELECT
  "cloud_vms"."id",
  COALESCE("cloud_vms"."billing_team_id", "cloud_vms"."user_id"),
  'migration',
  "cloud_vms"."status"::text,
  CURRENT_TIMESTAMP
FROM "cloud_vms"
WHERE "cloud_vms"."status" <> 'destroyed'
  AND NOT EXISTS (
    SELECT 1
    FROM "cloud_vm_state_transitions" AS existing
    WHERE existing."vm_id" = "cloud_vms"."id"
  );

CREATE INDEX IF NOT EXISTS "cloud_vm_state_transitions_team_created_idx"
  ON "cloud_vm_state_transitions" USING btree ("billing_team_id", "created_at");
CREATE INDEX IF NOT EXISTS "cloud_vm_state_transitions_vm_created_idx"
  ON "cloud_vm_state_transitions" USING btree ("vm_id", "created_at");
