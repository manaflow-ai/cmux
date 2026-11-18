-- iOS in-app purchases: renewal re-check, notification backfill, retry backoff
-- (docs/billing/ios-in-app-purchases.md). Additive: new nullable columns, NOT
-- NULL columns with defaults, and one new table, so code from before this
-- migration keeps working on the result. Replay-safe: every statement is a
-- no-op where its object already exists.

-- When the cron last got an App Store Server API answer for the subscription.
ALTER TABLE "apple_subscriptions" ADD COLUMN IF NOT EXISTS "apple_checked_at" timestamp with time zone;--> statement-breakpoint

-- Retry backoff and dead letter for notifications whose application keeps failing.
ALTER TABLE "apple_notifications"
  ADD COLUMN IF NOT EXISTS "attempt_count" integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS "next_attempt_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "dead_lettered_at" timestamp with time zone;--> statement-breakpoint

-- Where the Get Notification History backfill resumes, per bundle and environment.
CREATE TABLE IF NOT EXISTS "apple_notification_history_cursors" (
  "bundle_id" text NOT NULL,
  "environment" text NOT NULL,
  "next_start_at" timestamp with time zone NOT NULL,
  "window_start_at" timestamp with time zone,
  "window_end_at" timestamp with time zone,
  "pagination_token" text,
  "retryable_runs" integer DEFAULT 0 NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "apple_notification_history_cursors_pkey" PRIMARY KEY ("bundle_id", "environment")
);--> statement-breakpoint

-- For a database that ran an earlier copy of this migration without the column.
ALTER TABLE "apple_notification_history_cursors" ADD COLUMN IF NOT EXISTS "retryable_runs" integer DEFAULT 0 NOT NULL;
