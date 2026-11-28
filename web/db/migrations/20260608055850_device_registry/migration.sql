CREATE TABLE "device_app_instances" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"device_id" uuid NOT NULL,
	"team_id" text NOT NULL,
	"tag" text DEFAULT 'default' NOT NULL,
	"routes" jsonb DEFAULT '[]' NOT NULL,
	"labels" jsonb DEFAULT '{}' NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "devices" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"team_id" text NOT NULL,
	"device_uuid" uuid NOT NULL,
	"user_id" text NOT NULL,
	"platform" text NOT NULL,
	"display_name" text,
	"labels" jsonb DEFAULT '{}' NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "device_app_instances_device_tag_unique" ON "device_app_instances" ("device_id","tag");--> statement-breakpoint
CREATE INDEX "device_app_instances_team_last_seen_idx" ON "device_app_instances" ("team_id","last_seen_at");--> statement-breakpoint
CREATE UNIQUE INDEX "devices_team_device_uuid_unique" ON "devices" ("team_id","device_uuid");--> statement-breakpoint
CREATE INDEX "devices_team_last_seen_idx" ON "devices" ("team_id","last_seen_at");--> statement-breakpoint
CREATE INDEX "devices_team_user_idx" ON "devices" ("team_id","user_id");--> statement-breakpoint
ALTER TABLE "device_app_instances" ADD CONSTRAINT "device_app_instances_device_id_devices_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE CASCADE;