-- One-time sign-in hand-off codes (web/app/lib/handoff-codes.ts): an
-- authorization code with PKCE, issued to a fixed client and redirect URI.
-- Only the SHA-256 of a code is stored. A new table; the previous web build
-- never reads it.
CREATE TABLE IF NOT EXISTS "auth_handoff_codes" (
  "code_hash" text PRIMARY KEY NOT NULL,
  "client_id" text NOT NULL,
  "redirect_uri" text NOT NULL,
  "user_id" text NOT NULL,
  "code_challenge" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "auth_handoff_codes_hash_check" CHECK ("auth_handoff_codes"."code_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "auth_handoff_codes_challenge_check" CHECK ("auth_handoff_codes"."code_challenge" ~ '^[A-Za-z0-9_-]{43}$'),
  CONSTRAINT "auth_handoff_codes_client_check" CHECK (char_length("auth_handoff_codes"."client_id") between 1 and 64),
  CONSTRAINT "auth_handoff_codes_expiry_check" CHECK ("auth_handoff_codes"."expires_at" > "auth_handoff_codes"."created_at")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "auth_handoff_codes_expires_idx" ON "auth_handoff_codes" USING btree ("expires_at");
