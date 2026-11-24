-- The cmux Cloud $1 pass (web/services/billing/cloudIntro.ts): one row per pass
-- checkout. Expand-only: a new table nothing else reads, so the previous web
-- build is unaffected. Replay-safe: every statement is IF NOT EXISTS.
CREATE TABLE IF NOT EXISTS "cloud_intro_passes" (
  "checkout_session_id" text PRIMARY KEY NOT NULL,
  "stack_user_id" text NOT NULL,
  "stack_team_ids" text[] DEFAULT '{}'::text[] NOT NULL,
  "status" text DEFAULT 'open' NOT NULL,
  "refusal" text,
  "payment_intent_id" text,
  "stripe_customer_id" text,
  "card_fingerprint" text,
  "card_funding" text,
  "renew_on_plus" boolean DEFAULT false NOT NULL,
  "payment_method_id" text,
  "refund_id" text,
  "started_at" timestamp with time zone,
  "ends_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_intro_passes_status_check" CHECK ("status" in ('open', 'granted', 'refused'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_intro_passes_stack_user_idx" ON "cloud_intro_passes" ("stack_user_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_intro_passes_stack_team_ids_idx" ON "cloud_intro_passes" USING gin ("stack_team_ids");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_intro_passes_granted_started_idx" ON "cloud_intro_passes" ("started_at")
  WHERE "status" = 'granted';
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_intro_passes_payment_intent_unique" ON "cloud_intro_passes" ("payment_intent_id")
  WHERE "payment_intent_id" IS NOT NULL;
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_intro_passes_granted_user_unique" ON "cloud_intro_passes" ("stack_user_id")
  WHERE "status" = 'granted';
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_intro_passes_granted_card_unique" ON "cloud_intro_passes" ("card_fingerprint")
  WHERE "status" = 'granted';
