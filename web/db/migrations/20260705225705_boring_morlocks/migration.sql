CREATE TYPE "coderouter_credential_class" AS ENUM('oauth', 'byok', 'managed');--> statement-breakpoint
CREATE TYPE "coderouter_credential_kind" AS ENUM('oauth', 'api_key');--> statement-breakpoint
CREATE TYPE "coderouter_credential_status" AS ENUM('active', 'needs_reauth', 'disabled');--> statement-breakpoint
CREATE TYPE "coderouter_family" AS ENUM('anthropic', 'openai');--> statement-breakpoint
CREATE TABLE "coderouter_credentials" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"pool_id" uuid NOT NULL,
	"kind" "coderouter_credential_kind" NOT NULL,
	"class" "coderouter_credential_class" NOT NULL,
	"status" "coderouter_credential_status" DEFAULT 'active'::"coderouter_credential_status" NOT NULL,
	"label" text,
	"provider_email" text,
	"provider_account_id" text,
	"encrypted_secret" text,
	"meta" jsonb DEFAULT '{}' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "coderouter_keys" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"team_id" text NOT NULL,
	"name" text NOT NULL,
	"secret_hash" text NOT NULL,
	"policy" jsonb DEFAULT '{}' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"revoked_at" timestamp with time zone,
	"last_used_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "coderouter_pools" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"team_id" text NOT NULL,
	"billing_customer_type" text DEFAULT 'team' NOT NULL,
	"family" "coderouter_family" NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "coderouter_usage_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"event_id" text NOT NULL,
	"team_id" text NOT NULL,
	"key_id" uuid,
	"credential_id" uuid,
	"family" text NOT NULL,
	"endpoint_class" text NOT NULL,
	"model" text,
	"credential_class" text NOT NULL,
	"status" integer NOT NULL,
	"input_tokens" bigint DEFAULT 0 NOT NULL,
	"output_tokens" bigint DEFAULT 0 NOT NULL,
	"cache_read_tokens" bigint DEFAULT 0 NOT NULL,
	"cache_write_tokens" bigint DEFAULT 0 NOT NULL,
	"estimated" boolean DEFAULT false NOT NULL,
	"cost_micros" bigint,
	"latency_ms" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "coderouter_credentials_pool_idx" ON "coderouter_credentials" ("pool_id");--> statement-breakpoint
CREATE INDEX "coderouter_keys_team_idx" ON "coderouter_keys" ("team_id");--> statement-breakpoint
CREATE UNIQUE INDEX "coderouter_pools_team_family_unique" ON "coderouter_pools" ("team_id","family");--> statement-breakpoint
CREATE UNIQUE INDEX "coderouter_usage_events_event_id_unique" ON "coderouter_usage_events" ("event_id");--> statement-breakpoint
CREATE INDEX "coderouter_usage_events_team_created_idx" ON "coderouter_usage_events" ("team_id","created_at");--> statement-breakpoint
ALTER TABLE "coderouter_credentials" ADD CONSTRAINT "coderouter_credentials_pool_id_coderouter_pools_id_fkey" FOREIGN KEY ("pool_id") REFERENCES "coderouter_pools"("id") ON DELETE CASCADE;