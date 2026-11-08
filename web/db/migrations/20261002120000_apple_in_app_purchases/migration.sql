CREATE TABLE IF NOT EXISTS "apple_account_tokens" (
	"user_id" text PRIMARY KEY NOT NULL,
	"app_account_token" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "apple_account_tokens_app_account_token_unique" ON "apple_account_tokens" ("app_account_token");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_subscriptions" (
	"original_transaction_id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"app_account_token" uuid,
	"bundle_id" text NOT NULL,
	"environment" text NOT NULL,
	"product_id" text NOT NULL,
	"plan_id" text NOT NULL,
	"status" text NOT NULL,
	"auto_renew_enabled" boolean,
	"auto_renew_product_id" text,
	"purchase_date" timestamp with time zone,
	"original_purchase_date" timestamp with time zone,
	"expires_at" timestamp with time zone,
	"grace_period_expires_at" timestamp with time zone,
	"storefront" text,
	"currency" text,
	"price_milliunits" bigint,
	"last_transaction_id" text,
	"revoked_at" timestamp with time zone,
	"revocation_reason" integer,
	"state_signed_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "apple_subscriptions_status_check" CHECK ("status" in ('active', 'grace_period', 'billing_retry', 'expired', 'revoked'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_subscriptions_user_id_idx" ON "apple_subscriptions" ("user_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_subscriptions_expires_at_idx" ON "apple_subscriptions" ("expires_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_transactions" (
	"transaction_id" text PRIMARY KEY NOT NULL,
	"original_transaction_id" text NOT NULL,
	"user_id" text NOT NULL,
	"product_id" text NOT NULL,
	"plan_id" text,
	"environment" text NOT NULL,
	"type" text,
	"purchase_date" timestamp with time zone,
	"expires_at" timestamp with time zone,
	"price_milliunits" bigint,
	"currency" text,
	"storefront" text,
	"offer_type" integer,
	"revoked_at" timestamp with time zone,
	"payload" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_transactions_original_transaction_id_idx" ON "apple_transactions" ("original_transaction_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_transactions_user_id_idx" ON "apple_transactions" ("user_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_transactions_purchase_date_idx" ON "apple_transactions" ("purchase_date");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_notifications" (
	"notification_uuid" text PRIMARY KEY NOT NULL,
	"notification_type" text NOT NULL,
	"subtype" text,
	"environment" text NOT NULL,
	"original_transaction_id" text,
	"signed_date" timestamp with time zone NOT NULL,
	"payload" jsonb NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"processed_at" timestamp with time zone,
	"error" text
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_notifications_original_transaction_id_idx" ON "apple_notifications" ("original_transaction_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_notifications_pending_idx" ON "apple_notifications" ("received_at") WHERE "processed_at" IS NULL;
