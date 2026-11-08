ALTER TABLE "notification_send_events"
  ADD COLUMN "correlation_id" text,
  ADD COLUMN "payload_fingerprint" text,
  ADD COLUMN "event_kind" text DEFAULT 'notify' NOT NULL,
  ADD COLUMN "initial_targets" jsonb,
  ADD COLUMN "result_summary" jsonb,
  ADD COLUMN "result_outcomes" jsonb,
  ADD COLUMN "expires_at" timestamp with time zone,
  ADD COLUMN "lease_until" timestamp with time zone;

-- Correlation writes are serialized by the per-user pg_advisory_xact_lock in
-- recordPushSendOrThrow. Avoiding a new index keeps this rolling migration from
-- blocking notification_send_events writes on a live database.
