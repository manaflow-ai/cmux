DO $$ BEGIN
  CREATE TYPE "team_invite_role" AS ENUM ('admin', 'member');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "team_invite_roles" (
	"stack_team_id" text NOT NULL,
	"email" text NOT NULL,
	"role" "team_invite_role" DEFAULT 'member' NOT NULL,
	"invited_by_user_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "team_invite_roles_pkey" PRIMARY KEY ("stack_team_id", "email"),
	CONSTRAINT "team_invite_roles_email_check" CHECK ("email" = lower("email") AND char_length("email") BETWEEN 3 AND 254)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "team_invite_links" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"stack_team_id" text NOT NULL,
	"token_hash" text NOT NULL,
	"role" "team_invite_role" DEFAULT 'member' NOT NULL,
	"created_by_user_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	"max_uses" integer,
	"use_count" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "team_invite_links_member_only" CHECK ("role" = 'member'),
	CONSTRAINT "team_invite_links_token_hash_check" CHECK ("token_hash" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "team_invite_links_max_uses_check" CHECK ("max_uses" IS NULL OR "max_uses" > 0),
	CONSTRAINT "team_invite_links_use_count_check" CHECK ("use_count" >= 0 AND ("max_uses" IS NULL OR "use_count" <= "max_uses"))
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "team_invite_links_token_hash_unique" ON "team_invite_links" ("token_hash");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "team_invite_links_team_created_idx" ON "team_invite_links" ("stack_team_id", "created_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "team_invite_link_redemptions" (
	"link_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"redeemed_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "team_invite_link_redemptions_pkey" PRIMARY KEY ("link_id", "user_id"),
	CONSTRAINT "team_invite_link_redemptions_link_id_team_invite_links_id_fk" FOREIGN KEY ("link_id") REFERENCES "team_invite_links"("id") ON DELETE CASCADE
);
