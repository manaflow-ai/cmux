ALTER TABLE "cloud_vms" ADD COLUMN "slug" text;
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_billing_team_slug_live_unique" ON "cloud_vms" ("billing_team_id", "slug")
  WHERE "billing_team_id" IS NOT NULL AND "slug" IS NOT NULL AND "status" IN ('provisioning', 'running', 'paused');
