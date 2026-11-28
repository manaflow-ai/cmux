ALTER TABLE "cloud_vm_leases" ADD COLUMN "provider_identity_handle" text;--> statement-breakpoint
ALTER TABLE "cloud_vm_leases" ADD COLUMN "session_id" text;--> statement-breakpoint
ALTER TABLE "cloud_vm_leases" ADD COLUMN "transport" text;--> statement-breakpoint
ALTER TABLE "cloud_vm_leases" ADD COLUMN "metadata" jsonb DEFAULT '{}' NOT NULL;--> statement-breakpoint
ALTER TABLE "cloud_vm_leases" ADD COLUMN "revoked_at" timestamp with time zone;--> statement-breakpoint
DROP INDEX "cloud_vms_user_idempotency_key_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_user_idempotency_key_unique" ON "cloud_vms" ("user_id","idempotency_key") WHERE "idempotency_key" is not null;--> statement-breakpoint
DROP INDEX "cloud_vms_provider_vm_id_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_provider_vm_id_unique" ON "cloud_vms" ("provider","provider_vm_id") WHERE "provider_vm_id" is not null;--> statement-breakpoint
CREATE INDEX "cloud_vm_leases_identity_idx" ON "cloud_vm_leases" ("provider_identity_handle");