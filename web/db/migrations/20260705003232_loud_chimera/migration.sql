CREATE TABLE "billing_email_claims" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"email" text NOT NULL,
	"stripe_customer_id" text NOT NULL,
	"stack_user_id" text NOT NULL,
	"plan" text NOT NULL,
	"claimed_by_user_id" text,
	"claimed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "stripe_customers" (
	"id" text PRIMARY KEY,
	"stack_user_id" text NOT NULL,
	"email" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "stripe_subscriptions" (
	"id" text PRIMARY KEY,
	"customer_id" text NOT NULL,
	"stack_user_id" text NOT NULL,
	"status" text NOT NULL,
	"price_id" text,
	"plan" text NOT NULL,
	"current_period_end" timestamp with time zone,
	"cancel_at_period_end" boolean DEFAULT false NOT NULL,
	"raw" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "stripe_webhook_events" (
	"id" text PRIMARY KEY,
	"type" text NOT NULL,
	"payload_hash" text,
	"processed_at" timestamp with time zone,
	"error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "billing_email_claims_email_idx" ON "billing_email_claims" ("email");--> statement-breakpoint
CREATE UNIQUE INDEX "stripe_customers_stack_user_id_unique" ON "stripe_customers" ("stack_user_id");--> statement-breakpoint
CREATE INDEX "stripe_subscriptions_customer_id_idx" ON "stripe_subscriptions" ("customer_id");--> statement-breakpoint
CREATE INDEX "stripe_subscriptions_stack_user_id_idx" ON "stripe_subscriptions" ("stack_user_id");