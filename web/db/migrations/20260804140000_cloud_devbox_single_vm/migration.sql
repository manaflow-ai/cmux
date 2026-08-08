CREATE TABLE IF NOT EXISTS "cloud_devboxes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"vm_id" uuid NOT NULL,
	"volume_id" text NOT NULL,
	"volume_name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"released_at" timestamp with time zone
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "cloud_devboxes" ADD CONSTRAINT "cloud_devboxes_vm_id_cloud_vms_id_fk" FOREIGN KEY ("vm_id") REFERENCES "public"."cloud_vms"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_devboxes_user_active_unique" ON "cloud_devboxes" ("user_id") WHERE "released_at" is null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_devboxes_vm_id_idx" ON "cloud_devboxes" ("vm_id");
