-- The Stripe webhook inbox: a verified event is stored and answered 2xx, then
-- processed from here with retries. Expand-only; every column is nullable or
-- has a default, so the previous web build keeps reading and writing the table.
-- The defaults use `now()`, which is stable, so they do not rewrite the table:
-- existing rows get this migration's time.
--
-- The previous build inserts a row and processes it in the same request, with
-- no lease. The `lease_expires_at` default gives each such row a lease of 15
-- minutes, longer than any function runs, so the inbox never claims an event
-- that build is still applying. The inbox's own inserts set it to null.
ALTER TABLE "stripe_webhook_events"
  ADD COLUMN IF NOT EXISTS "object_key" text,
  ADD COLUMN IF NOT EXISTS "event_created_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "attempts" integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS "next_attempt_at" timestamp with time zone DEFAULT now(),
  ADD COLUMN IF NOT EXISTS "lease_expires_at" timestamp with time zone DEFAULT (now() + interval '15 minutes'),
  ADD COLUMN IF NOT EXISTS "skip_reason" text;
