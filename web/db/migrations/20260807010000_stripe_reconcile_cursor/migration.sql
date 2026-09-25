ALTER TABLE "stripe_subscriptions"
  ADD COLUMN IF NOT EXISTS "last_reconciled_at" timestamp with time zone;

CREATE INDEX IF NOT EXISTS "stripe_subscriptions_reconcile_cursor_idx"
  ON "stripe_subscriptions"
  ("last_reconciled_at" ASC NULLS FIRST, "id" ASC);
