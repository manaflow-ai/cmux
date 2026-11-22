-- iOS in-app purchases: a paid higher plan outlives an early renewal into a
-- lower one (docs/billing/ios-in-app-purchases.md). Apple charges a renewal
-- up to a day before the period ends, so a downgrade's Pro renewal can be
-- written while the paid Max period still runs; these columns keep Max until
-- then. Additive and nullable, so code from before this migration keeps
-- working on the result. Replay-safe.
ALTER TABLE "apple_subscriptions"
  ADD COLUMN IF NOT EXISTS "carried_plan_id" text,
  ADD COLUMN IF NOT EXISTS "carried_until" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "carried_transaction_id" text;
