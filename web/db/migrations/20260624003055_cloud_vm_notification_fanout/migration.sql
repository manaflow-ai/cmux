CREATE TYPE "cloud_vm_notification_delivery_status" AS ENUM('pending', 'sent', 'failed', 'read', 'dismissed');--> statement-breakpoint
CREATE TYPE "cloud_vm_notification_severity" AS ENUM('info', 'success', 'warning', 'error');--> statement-breakpoint
CREATE TABLE "cloud_vm_notification_deliveries" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"event_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"target_key" text NOT NULL,
	"device_id" uuid,
	"app_instance_id" uuid,
	"channel" text NOT NULL,
	"status" "cloud_vm_notification_delivery_status" DEFAULT 'pending'::"cloud_vm_notification_delivery_status" NOT NULL,
	"error_code" text,
	"error_message" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"sent_at" timestamp with time zone,
	"read_at" timestamp with time zone,
	"dismissed_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "cloud_vm_notification_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"vm_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"billing_team_id" text,
	"provider_session_id" text,
	"severity" "cloud_vm_notification_severity" DEFAULT 'info'::"cloud_vm_notification_severity" NOT NULL,
	"source" text DEFAULT 'vm' NOT NULL,
	"title" text NOT NULL,
	"body" text NOT NULL,
	"action" jsonb DEFAULT '{}' NOT NULL,
	"metadata" jsonb DEFAULT '{}' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_notification_deliveries_event_channel_target_unique" ON "cloud_vm_notification_deliveries" ("event_id","channel","target_key");--> statement-breakpoint
CREATE INDEX "cloud_vm_notification_deliveries_user_status_created_idx" ON "cloud_vm_notification_deliveries" ("user_id","status","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vm_notification_deliveries_event_status_idx" ON "cloud_vm_notification_deliveries" ("event_id","status");--> statement-breakpoint
CREATE INDEX "cloud_vm_notification_events_user_created_idx" ON "cloud_vm_notification_events" ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "cloud_vm_notification_events_vm_session_created_idx" ON "cloud_vm_notification_events" ("vm_id","provider_session_id","created_at");--> statement-breakpoint
ALTER TABLE "cloud_vm_notification_deliveries" ADD CONSTRAINT "cloud_vm_notification_deliveries_BCCTXPyvFIdZ_fkey" FOREIGN KEY ("event_id") REFERENCES "cloud_vm_notification_events"("id") ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE "cloud_vm_notification_deliveries" ADD CONSTRAINT "cloud_vm_notification_deliveries_device_id_devices_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE SET NULL;--> statement-breakpoint
ALTER TABLE "cloud_vm_notification_deliveries" ADD CONSTRAINT "cloud_vm_notification_deliveries_r9pkdG2le9Zk_fkey" FOREIGN KEY ("app_instance_id") REFERENCES "device_app_instances"("id") ON DELETE SET NULL;--> statement-breakpoint
ALTER TABLE "cloud_vm_notification_events" ADD CONSTRAINT "cloud_vm_notification_events_vm_id_cloud_vms_id_fkey" FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id") ON DELETE CASCADE;
