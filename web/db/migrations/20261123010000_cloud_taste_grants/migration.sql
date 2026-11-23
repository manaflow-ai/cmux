-- The cmux Cloud free week (web/services/billing/cloudTaste.ts): one row per
-- person ever granted one. Expand-only: a new table nothing else reads, so the
-- previous web build is unaffected. Replay-safe: every statement is IF NOT EXISTS.
CREATE TABLE IF NOT EXISTS "cloud_taste_grants" (
  "stack_user_id" text PRIMARY KEY NOT NULL,
  "stack_team_ids" text[] DEFAULT '{}'::text[] NOT NULL,
  "started_at" timestamp with time zone NOT NULL,
  "ends_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_taste_grants_stack_team_ids_idx" ON "cloud_taste_grants" USING gin ("stack_team_ids");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_taste_grants_started_idx" ON "cloud_taste_grants" ("started_at");
