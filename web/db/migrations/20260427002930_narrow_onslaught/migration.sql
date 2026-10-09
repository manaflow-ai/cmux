ALTER TABLE "cloud_vm_usage_events" ADD COLUMN "billing_team_id" text;--> statement-breakpoint
ALTER TABLE "cloud_vm_usage_events" ADD COLUMN "billing_plan_id" text;--> statement-breakpoint
ALTER TABLE "cloud_vms" ADD COLUMN "billing_team_id" text;--> statement-breakpoint
ALTER TABLE "cloud_vms" ADD COLUMN "billing_plan_id" text;--> statement-breakpoint
CREATE INDEX "cloud_vm_usage_events_billing_team_created_idx" ON "cloud_vm_usage_events" ("billing_team_id","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vms_billing_team_status_idx" ON "cloud_vms" ("billing_team_id","status");