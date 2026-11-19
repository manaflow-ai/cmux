-- One-time native sign-in codes for the PKCE hand-off to the app. Only the
-- code's SHA-256 is stored; each row lives at most 60 seconds and is deleted
-- by its first redemption. New table only, so the previous web build is
-- unaffected.
CREATE TABLE IF NOT EXISTS "native_sign_in_codes" (
  "code_hash" text PRIMARY KEY NOT NULL,
  "code_challenge" text NOT NULL,
  "scheme" text NOT NULL,
  "user_id" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "native_sign_in_codes_hash_check" CHECK ("code_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "native_sign_in_codes_challenge_check" CHECK ("code_challenge" ~ '^[A-Za-z0-9_-]{43}$')
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "native_sign_in_codes_expiry_idx" ON "native_sign_in_codes" ("expires_at");
