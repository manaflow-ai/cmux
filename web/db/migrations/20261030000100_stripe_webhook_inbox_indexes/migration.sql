CREATE INDEX CONCURRENTLY IF NOT EXISTS "stripe_webhook_events_due_idx"
  ON "stripe_webhook_events" ("next_attempt_at")
  WHERE "processed_at" IS NULL;--> statement-breakpoint
CREATE INDEX CONCURRENTLY IF NOT EXISTS "stripe_webhook_events_object_key_idx"
  ON "stripe_webhook_events" ("object_key", "event_created_at")
  WHERE "object_key" IS NOT NULL;
