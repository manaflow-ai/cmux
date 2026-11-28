ALTER TABLE "notification_send_events"
  ADD COLUMN "lease_token" uuid,
  ADD COLUMN "retry_not_before" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "device_tokens"
  ADD COLUMN "delivery_lease_until" timestamp with time zone,
  ADD COLUMN "delivery_lease_token" uuid;
--> statement-breakpoint
DROP INDEX IF EXISTS "notification_send_events_user_correlation_unique";
--> statement-breakpoint
UPDATE "notification_send_events"
SET
  "initial_targets" = NULL,
  "result_outcomes" = NULL,
  "result_summary" = jsonb_build_object(
    'sent', 0,
    'devices', "device_count",
    'pruned', 0,
    'transientFailures', 0,
    'permanentFailures', "device_count"
  ),
  "expires_at" = now(),
  "lease_until" = NULL,
  "retry_not_before" = NULL;
