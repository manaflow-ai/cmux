CREATE TYPE "public"."vm_lease_kind" AS ENUM('pty', 'rpc', 'ssh');--> statement-breakpoint
CREATE TYPE "public"."vm_provider" AS ENUM('e2b', 'freestyle');--> statement-breakpoint
CREATE TYPE "public"."vm_status" AS ENUM('provisioning', 'running', 'failed', 'paused', 'destroyed');--> statement-breakpoint
CREATE TABLE "cloud_vm_leases" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"vm_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"kind" "vm_lease_kind" NOT NULL,
	"token_hash" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"consumed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "cloud_vm_usage_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"vm_id" uuid,
	"event_type" text NOT NULL,
	"provider" "vm_provider",
	"image_id" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "cloud_vms" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"provider" "vm_provider" NOT NULL,
	"provider_vm_id" text,
	"image_id" text NOT NULL,
	"image_version" text,
	"status" "vm_status" DEFAULT 'provisioning' NOT NULL,
	"idempotency_key" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"destroyed_at" timestamp with time zone,
	"failure_code" text,
	"failure_message" text
);
--> statement-breakpoint
ALTER TABLE "cloud_vm_leases" ADD CONSTRAINT "cloud_vm_leases_vm_id_cloud_vms_id_fk" FOREIGN KEY ("vm_id") REFERENCES "public"."cloud_vms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "cloud_vm_usage_events" ADD CONSTRAINT "cloud_vm_usage_events_vm_id_cloud_vms_id_fk" FOREIGN KEY ("vm_id") REFERENCES "public"."cloud_vms"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "cloud_vm_leases_vm_kind_idx" ON "cloud_vm_leases" USING btree ("vm_id","kind");--> statement-breakpoint
CREATE INDEX "cloud_vm_leases_user_expires_idx" ON "cloud_vm_leases" USING btree ("user_id","expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_leases_token_hash_unique" ON "cloud_vm_leases" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "cloud_vm_usage_events_user_created_idx" ON "cloud_vm_usage_events" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vm_usage_events_vm_created_idx" ON "cloud_vm_usage_events" USING btree ("vm_id","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vm_usage_events_type_created_idx" ON "cloud_vm_usage_events" USING btree ("event_type","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vms_user_status_idx" ON "cloud_vms" USING btree ("user_id","status");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_user_idempotency_key_unique" ON "cloud_vms" USING btree ("user_id","idempotency_key") WHERE "cloud_vms"."idempotency_key" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vms_provider_vm_id_unique" ON "cloud_vms" USING btree ("provider","provider_vm_id") WHERE "cloud_vms"."provider_vm_id" is not null;