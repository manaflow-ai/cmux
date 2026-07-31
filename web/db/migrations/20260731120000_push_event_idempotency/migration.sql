ALTER TABLE "notification_send_events"
  ADD COLUMN "correlation_id" text,
  ADD COLUMN "payload_fingerprint" text,
  ADD COLUMN "event_kind" text DEFAULT 'notify' NOT NULL,
  ADD COLUMN "initial_targets" jsonb,
  ADD COLUMN "result_summary" jsonb,
  ADD COLUMN "result_outcomes" jsonb,
  ADD COLUMN "expires_at" timestamp with time zone,
  ADD COLUMN "lease_until" timestamp with time zone;
--> statement-breakpoint
CREATE UNIQUE INDEX "notification_send_events_user_correlation_unique"
  ON "notification_send_events" ("user_id", "correlation_id")
  WHERE "correlation_id" IS NOT NULL;
