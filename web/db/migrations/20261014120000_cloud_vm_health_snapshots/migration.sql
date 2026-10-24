-- Staff Cloud VM health sweep snapshots. Additive: only the new health cron
-- writes this table and only the new staff page reads it, so old app code
-- runs unchanged before and after the migration.
CREATE TABLE IF NOT EXISTS "cloud_vm_health_snapshots" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"attention_needed" boolean NOT NULL,
	"report" jsonb NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_health_snapshots_created_at_idx" ON "cloud_vm_health_snapshots" USING btree ("created_at");
