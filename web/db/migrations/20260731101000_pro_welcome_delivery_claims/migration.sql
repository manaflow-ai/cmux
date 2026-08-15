ALTER TABLE "pro_welcome_fulfillments"
  ADD COLUMN "delivery_started_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "pro_welcome_fulfillments"
  ADD COLUMN "attempt_lease_expires_at" timestamp with time zone;
