ALTER TABLE "coderouter_accounts"
  ADD COLUMN "usage" jsonb,
  ADD COLUMN "usage_error" text,
  ADD COLUMN "usage_fetched_at" timestamp with time zone,
  ADD COLUMN "usage_refresh_claimed_at" timestamp with time zone;
