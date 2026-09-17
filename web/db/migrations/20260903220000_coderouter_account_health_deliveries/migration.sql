-- Record each successful account-health delivery separately. The recipient is
-- a normalized email hash, so partial team batches can retry only the failed
-- recipient without storing another plain-email copy.
CREATE TABLE "coderouter_account_health_deliveries" (
  "source" text NOT NULL,
  "account_id" text NOT NULL,
  "recipient_hash" text NOT NULL,
  "sent_at" timestamp with time zone DEFAULT now() NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_account_health_deliveries_pkey"
    PRIMARY KEY ("source", "account_id", "recipient_hash"),
  CONSTRAINT "coderouter_account_health_deliveries_source_check"
    CHECK ("source" IN ('claude', 'subscription')),
  CONSTRAINT "coderouter_account_health_deliveries_hash_check"
    CHECK ("recipient_hash" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE INDEX "coderouter_account_health_deliveries_account_idx"
  ON "coderouter_account_health_deliveries" ("source", "account_id");
