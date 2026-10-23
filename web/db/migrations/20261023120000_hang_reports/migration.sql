-- Opt-in hang reports from cmux NEXT Nightly. Additive: only the new
-- /api/hang-reports route writes this table and only the new retention cron
-- and the read-only top-frames script read it, so old app code runs unchanged
-- before and after the migration. No IP address or user agent column exists.
CREATE TABLE IF NOT EXISTS "hang_reports" (
	"report_id" uuid PRIMARY KEY NOT NULL,
	"install_id" uuid NOT NULL,
	"received_day" date NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"app_version" text,
	"app_build" text,
	"channel" text,
	"os_version" text,
	"arch" text,
	"chip" text,
	"cores" integer,
	"memory_gb" integer,
	"counts" jsonb,
	"payload" jsonb NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hang_reports_install_day_idx" ON "hang_reports" USING btree ("install_id","received_day");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hang_reports_received_at_idx" ON "hang_reports" USING btree ("received_at");
