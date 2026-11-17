-- Double billing incidents: one cmux account paying for a personal plan
-- through both Stripe and the App Store (services/billing/doubleBilling.ts,
-- docs/billing/ios-in-app-purchases.md "Double billing"). Additive: only the
-- double billing detectors write it and only the admin endpoint reads it, so
-- code from before this migration runs unchanged. Replay-safe.
CREATE TABLE IF NOT EXISTS "billing_double_subscription_incidents" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"stripe_subscription_id" text NOT NULL,
	"apple_original_transaction_id" text NOT NULL,
	"stripe_plan_id" text NOT NULL,
	"stripe_status" text NOT NULL,
	"apple_plan_id" text NOT NULL,
	"apple_status" text NOT NULL,
	"apple_environment" text NOT NULL,
	"apple_auto_renew_enabled" boolean,
	"first_detected_by" text NOT NULL,
	"last_detected_by" text NOT NULL,
	"first_detected_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_detected_at" timestamp with time zone DEFAULT now() NOT NULL,
	"resolved_at" timestamp with time zone
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "billing_double_subscription_incidents_pair_unique" ON "billing_double_subscription_incidents" USING btree ("user_id","stripe_subscription_id","apple_original_transaction_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "billing_double_subscription_incidents_open_idx" ON "billing_double_subscription_incidents" USING btree ("last_detected_at") WHERE "resolved_at" is null;
