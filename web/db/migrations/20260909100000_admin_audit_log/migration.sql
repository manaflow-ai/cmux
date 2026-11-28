CREATE TABLE "admin_audit_log" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "actor_user_id" text NOT NULL,
  "actor_email" text,
  "action" text NOT NULL,
  "target_kind" text NOT NULL,
  "target_id" text,
  "target_label" text,
  "details" jsonb,
  "outcome" text NOT NULL,
  "error" text,
  "request_id" text,
  CONSTRAINT "admin_audit_log_outcome_check" CHECK ("outcome" in ('ok', 'error'))
);
--> statement-breakpoint
CREATE INDEX "admin_audit_log_created_at_idx" ON "admin_audit_log" ("created_at" DESC);
--> statement-breakpoint
CREATE INDEX "admin_audit_log_actor_created_at_idx" ON "admin_audit_log" ("actor_user_id", "created_at" DESC);
