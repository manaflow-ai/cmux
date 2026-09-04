ALTER TABLE "cloud_vms" ADD COLUMN "provider_status_observed_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "cloud_vms" ADD COLUMN "provider_status_checked_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "cloud_vms" ADD COLUMN "provider_status_probe_token" text;
--> statement-breakpoint
CREATE INDEX "cloud_vms_provider_status_checked_idx" ON "cloud_vms" ("provider_status_checked_at", "id")
  WHERE "provider_vm_id" IS NOT NULL AND "status" <> 'destroyed';
