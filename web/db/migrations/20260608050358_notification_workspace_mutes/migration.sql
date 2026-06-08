CREATE TABLE "notification_workspace_mutes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"user_id" text NOT NULL,
	"workspace_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "notification_workspace_mutes_user_idx" ON "notification_workspace_mutes" ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "notification_workspace_mutes_user_workspace_unique" ON "notification_workspace_mutes" ("user_id","workspace_id");