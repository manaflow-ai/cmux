CREATE TABLE IF NOT EXISTS "hexclave_users" (
	"id" text PRIMARY KEY NOT NULL,
	"primary_email" text,
	"display_name" text,
	"is_anonymous" boolean NOT NULL,
	"client_read_only_metadata" jsonb,
	"signed_up_at" timestamp with time zone NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	"raw" jsonb NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_users_primary_email_idx" ON "hexclave_users" (lower("primary_email"));
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_teams" (
	"id" text PRIMARY KEY NOT NULL,
	"display_name" text NOT NULL,
	"client_read_only_metadata" jsonb,
	"created_at" timestamp with time zone NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	"raw" jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_team_memberships" (
	"team_id" text NOT NULL,
	"user_id" text NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "hexclave_team_memberships_pkey" PRIMARY KEY ("team_id", "user_id"),
	CONSTRAINT "hexclave_team_memberships_team_id_hexclave_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "hexclave_teams"("id") ON DELETE CASCADE,
	CONSTRAINT "hexclave_team_memberships_user_id_hexclave_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "hexclave_users"("id") ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_team_memberships_user_idx" ON "hexclave_team_memberships" ("user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_team_permissions" (
	"team_id" text NOT NULL,
	"user_id" text NOT NULL,
	"permission_id" text NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "hexclave_team_permissions_pkey" PRIMARY KEY ("team_id", "user_id", "permission_id"),
	CONSTRAINT "hexclave_team_permissions_membership_fk" FOREIGN KEY ("team_id", "user_id") REFERENCES "hexclave_team_memberships"("team_id", "user_id") ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_team_permissions_user_idx" ON "hexclave_team_permissions" ("user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_project_permissions" (
	"user_id" text NOT NULL,
	"permission_id" text NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "hexclave_project_permissions_pkey" PRIMARY KEY ("user_id", "permission_id"),
	CONSTRAINT "hexclave_project_permissions_user_id_hexclave_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "hexclave_users"("id") ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_tombstones" (
	"entity_type" text NOT NULL,
	"entity_id" text NOT NULL,
	"deleted_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "hexclave_tombstones_pkey" PRIMARY KEY ("entity_type", "entity_id"),
	CONSTRAINT "hexclave_tombstones_entity_type_check" CHECK ("entity_type" in ('user', 'team'))
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_webhook_events" (
	"svix_id" text PRIMARY KEY NOT NULL,
	"event_type" text NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"processed_at" timestamp with time zone,
	"outcome" text NOT NULL,
	"attempts" integer DEFAULT 1 NOT NULL,
	CONSTRAINT "hexclave_webhook_events_outcome_check" CHECK ("outcome" in ('processed', 'ignored', 'invalid', 'failed'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_webhook_events_received_idx" ON "hexclave_webhook_events" ("received_at");
