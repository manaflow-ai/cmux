CREATE TYPE "cloud_vm_session_status" AS ENUM('running', 'detached', 'exited', 'closed');--> statement-breakpoint
CREATE TABLE "cloud_vm_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"vm_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"provider_session_id" text NOT NULL,
	"title" text,
	"kind" text DEFAULT 'terminal' NOT NULL,
	"status" "cloud_vm_session_status" DEFAULT 'running'::"cloud_vm_session_status" NOT NULL,
	"attachment_count" integer DEFAULT 0 NOT NULL,
	"effective_cols" integer,
	"effective_rows" integer,
	"last_known_cols" integer,
	"last_known_rows" integer,
	"scrollback_bytes" integer DEFAULT 0 NOT NULL,
	"metadata" jsonb DEFAULT '{}' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_attached_at" timestamp with time zone,
	"exited_at" timestamp with time zone,
	"closed_at" timestamp with time zone
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_sessions_vm_provider_session_unique" ON "cloud_vm_sessions" ("vm_id","provider_session_id");--> statement-breakpoint
CREATE INDEX "cloud_vm_sessions_user_status_updated_idx" ON "cloud_vm_sessions" ("user_id","status","updated_at");--> statement-breakpoint
CREATE INDEX "cloud_vm_sessions_vm_updated_idx" ON "cloud_vm_sessions" ("vm_id","updated_at");--> statement-breakpoint
ALTER TABLE "cloud_vm_sessions" ADD CONSTRAINT "cloud_vm_sessions_vm_id_cloud_vms_id_fkey" FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id") ON DELETE CASCADE;