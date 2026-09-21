-- M0 identity only: VM status and provider addresses keep their existing owner.
CREATE TABLE "cloud_runtimes" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "owner_team_id" text NOT NULL,
  "journal_session_id" text,
  "machine_id" uuid REFERENCES "cloud_vms"("id") ON DELETE SET NULL,
  "placement_generation" integer DEFAULT 1 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_runtimes_generation_positive" CHECK ("placement_generation" > 0),
  CONSTRAINT "cloud_runtimes_owner_nonempty" CHECK (length(trim("owner_team_id")) > 0)
);--> statement-breakpoint
CREATE INDEX "cloud_runtimes_owner_idx" ON "cloud_runtimes" ("owner_team_id");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_runtimes_machine_unique" ON "cloud_runtimes" ("machine_id");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_runtimes_journal_unique" ON "cloud_runtimes" ("journal_session_id");--> statement-breakpoint
CREATE TABLE "cloud_runtime_agent_bindings" (
  "runtime_id" uuid NOT NULL REFERENCES "cloud_runtimes"("id") ON DELETE CASCADE,
  "codex_thread_id" text NOT NULL,
  "root_chat_id" text NOT NULL,
  "parent_chat_id" text,
  PRIMARY KEY ("runtime_id", "codex_thread_id"),
  CONSTRAINT "cloud_runtime_agent_bindings_thread_nonempty" CHECK (length(trim("codex_thread_id")) > 0),
  CONSTRAINT "cloud_runtime_agent_bindings_root_nonempty" CHECK (length(trim("root_chat_id")) > 0)
);--> statement-breakpoint
-- Every live VM gets a fresh runtime identity. Base reset/recovery does not
-- restore a journal, so its VM is an ordinary M0 placement. Do not reuse Base
-- IDs or Base generations (failure recovery can roll that generation backward).
-- Historical destroyed machines have no recoverable lineage to adopt.
INSERT INTO "cloud_runtimes" ("owner_team_id", "machine_id", "created_at")
SELECT coalesce(nullif(trim("owner_team_id"), ''), nullif(trim("billing_team_id"), ''), "user_id"),
  "id", "created_at" FROM "cloud_vms"
WHERE "status" NOT IN ('failed', 'destroyed');
