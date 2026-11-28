DROP INDEX IF EXISTS "cloud_vms_user_idempotency_key_unique";--> statement-breakpoint
UPDATE "cloud_vms" SET "billing_team_id" = "user_id" WHERE "billing_team_id" IS NULL;--> statement-breakpoint
UPDATE "cloud_vm_usage_events" SET "billing_team_id" = "user_id" WHERE "billing_team_id" IS NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_billing_team_idempotency_key_unique" ON "cloud_vms" ("billing_team_id","idempotency_key") WHERE "billing_team_id" is not null and "idempotency_key" is not null;
