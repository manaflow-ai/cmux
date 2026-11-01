-- Opt-in hang reports from cmux NEXT Nightly. Additive: only the new
-- /api/hang-reports route writes this table and only the new retention cron
-- and the read-only top-frames script read it, so old app code runs unchanged
-- before and after the migration. No IP address or user agent column exists.
-- CREATE TABLE IF NOT EXISTS checks CREATE on the schema before it looks
-- for the table, so on production (table made by hand, migrator role with
-- DML grants only) a replay would fail with 42501. The table is created only
-- when no relation of its name exists.
DO $$
BEGIN
	IF to_regclass('public.hang_reports') IS NULL THEN
		CREATE TABLE "public"."hang_reports" (
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
	END IF;
END $$;
--> statement-breakpoint
-- Production's table was created by hand (owner postgres) before this file
-- reached main, and the migrator's role only has DML grants. CREATE INDEX
-- checks table ownership before IF NOT EXISTS, so each index is created only
-- when no relation of its name exists: the replay is then a real no-op.
DO $$
BEGIN
	IF to_regclass('public.hang_reports_install_day_idx') IS NULL THEN
		CREATE INDEX "hang_reports_install_day_idx" ON "public"."hang_reports" USING btree ("install_id","received_day");
	END IF;
END $$;
--> statement-breakpoint
DO $$
BEGIN
	IF to_regclass('public.hang_reports_received_at_idx') IS NULL THEN
		CREATE INDEX "hang_reports_received_at_idx" ON "public"."hang_reports" USING btree ("received_at");
	END IF;
END $$;
