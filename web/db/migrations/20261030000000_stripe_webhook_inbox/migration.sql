-- The Stripe webhook inbox: a verified event is stored and answered 2xx, then
-- processed from here with retries. Expand-only; every column is nullable or
-- has a default, so the previous web build keeps reading and writing the table.
-- `now()` is stable, so the default does not rewrite the table: existing rows
-- get this migration's time, which makes a still-unprocessed one due at once.
ALTER TABLE "stripe_webhook_events"
  ADD COLUMN IF NOT EXISTS "object_key" text,
  ADD COLUMN IF NOT EXISTS "event_created_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "attempts" integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS "next_attempt_at" timestamp with time zone DEFAULT now(),
  ADD COLUMN IF NOT EXISTS "lease_expires_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "skip_reason" text;
