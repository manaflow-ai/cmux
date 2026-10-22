-- Paywall and pricing experiments: sticky per-user assignments, the
-- append-only change log, and optimizer run snapshots. New tables only; no
-- existing table changes, so the running deployment is unaffected.
CREATE TABLE IF NOT EXISTS "paywall_assignments" (
	"user_id" text NOT NULL,
	"experiment" text NOT NULL,
	"variant" text NOT NULL,
	"payload" jsonb NOT NULL,
	"assigned_at" timestamp with time zone DEFAULT now() NOT NULL,
	"served_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "paywall_assignments_user_id_experiment_pk" PRIMARY KEY("user_id","experiment")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "paywall_experiment_changes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"experiment" text NOT NULL,
	"changed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"kind" text NOT NULL,
	"variant" text,
	"reason" text NOT NULL,
	"details" jsonb,
	"actor" text NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "paywall_experiment_changes_experiment_idx" ON "paywall_experiment_changes" ("experiment","changed_at" DESC);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "paywall_experiment_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"experiment" text NOT NULL,
	"ran_at" timestamp with time zone DEFAULT now() NOT NULL,
	"halted" boolean DEFAULT false NOT NULL,
	"snapshot" jsonb NOT NULL,
	"report_markdown" text NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "paywall_experiment_runs_experiment_idx" ON "paywall_experiment_runs" ("experiment","ran_at" DESC);
