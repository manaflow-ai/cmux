ALTER TABLE "stripe_subscriptions"
  ADD COLUMN "last_reconciled_at" timestamp with time zone;

CREATE INDEX "stripe_subscriptions_reconcile_cursor_idx"
  ON "stripe_subscriptions" ("last_reconciled_at", "id");
