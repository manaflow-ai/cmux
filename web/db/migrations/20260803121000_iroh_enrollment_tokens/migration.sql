-- One-use headless enrollment tokens for cmux-tui iroh peers. A signed-in user
-- mints a token (15-minute TTL, at most 8 outstanding per user), provisioning
-- injects it into the container, and the unauthenticated exchange route
-- consumes it exactly once for a Stack session. Only the SHA-256 hash of the
-- random token is persisted.
CREATE TABLE "iroh_enrollment_tokens" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "token_hash" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  CONSTRAINT "iroh_enrollment_tokens_token_hash_check"
    CHECK ("token_hash" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_enrollment_tokens_token_hash_unique"
  ON "iroh_enrollment_tokens" ("token_hash");
--> statement-breakpoint
CREATE INDEX "iroh_enrollment_tokens_user_expires_idx"
  ON "iroh_enrollment_tokens" ("user_id", "expires_at");
--> statement-breakpoint
CREATE INDEX "iroh_enrollment_tokens_expires_idx"
  ON "iroh_enrollment_tokens" ("expires_at", "id");
