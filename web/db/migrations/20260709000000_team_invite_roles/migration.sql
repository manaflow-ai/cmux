CREATE TYPE "team_invite_role" AS ENUM ('admin', 'member');
--> statement-breakpoint
CREATE TABLE "team_invite_roles" (
  "invitation_id" text PRIMARY KEY NOT NULL,
  "stack_team_id" text NOT NULL,
  "role" "team_invite_role" DEFAULT 'member' NOT NULL,
  "created_by_user_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "accepted_at" timestamp with time zone,
  "revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE INDEX "team_invite_roles_stack_team_idx" ON "team_invite_roles" ("stack_team_id");
