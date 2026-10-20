CREATE TABLE IF NOT EXISTS "hexclave_pending_revocations" (
	"team_id" text NOT NULL,
	"user_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "hexclave_pending_revocations_pkey" PRIMARY KEY ("team_id", "user_id")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_pending_revocations_user_idx" ON "hexclave_pending_revocations" ("user_id");
