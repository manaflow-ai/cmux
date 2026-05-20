CREATE TYPE "typefully_draft_status" AS ENUM('draft', 'archived');--> statement-breakpoint
CREATE TABLE "typefully_drafts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"user_id" text NOT NULL,
	"user_email" text NOT NULL,
	"title" text DEFAULT 'Untitled draft' NOT NULL,
	"thread" jsonb DEFAULT '[""]' NOT NULL,
	"status" "typefully_draft_status" DEFAULT 'draft'::"typefully_draft_status" NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "typefully_drafts_user_updated_idx" ON "typefully_drafts" ("user_id","updated_at");--> statement-breakpoint
CREATE INDEX "typefully_drafts_user_status_updated_idx" ON "typefully_drafts" ("user_id","status","updated_at");