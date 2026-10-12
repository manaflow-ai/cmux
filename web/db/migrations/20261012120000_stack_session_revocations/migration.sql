CREATE TABLE IF NOT EXISTS "stack_session_revocations" (
	"stack_session_id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"access_grant_id" uuid,
	"attempts" integer DEFAULT 0 NOT NULL,
	"next_attempt_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "stack_session_revocations_due_idx" ON "stack_session_revocations" ("next_attempt_at") WHERE "revoked_at" IS NULL;
