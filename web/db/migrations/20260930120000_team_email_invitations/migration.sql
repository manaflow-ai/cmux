CREATE TABLE IF NOT EXISTS "team_email_invitations" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"stack_team_id" text NOT NULL,
	"email" text NOT NULL,
	"role" "team_invite_role" DEFAULT 'member' NOT NULL,
	"invited_by_user_id" text NOT NULL,
	"token_hash" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_sent_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"revoked_at" timestamp with time zone,
	"accepted_at" timestamp with time zone,
	"accepted_by_user_id" text,
	"declined_at" timestamp with time zone,
	CONSTRAINT "team_email_invitations_email_check" CHECK ("email" = lower("email") and char_length("email") between 3 and 254),
	CONSTRAINT "team_email_invitations_token_hash_check" CHECK ("token_hash" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "team_email_invitations_token_hash_unique" ON "team_email_invitations" ("token_hash");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "team_email_invitations_team_created_idx" ON "team_email_invitations" ("stack_team_id","created_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "team_email_invitations_email_idx" ON "team_email_invitations" ("email");
