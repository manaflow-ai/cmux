CREATE TABLE "cloud_runtime_workspaces" (
  "runtime_id" uuid PRIMARY KEY NOT NULL REFERENCES "cloud_runtimes"("id") ON DELETE CASCADE,
  "owner_team_id" text NOT NULL,
  "workspace_id" text NOT NULL,
  "workspace_name" text NOT NULL,
  "provider" text DEFAULT 'freestyle' NOT NULL,
  "lifecycle" text DEFAULT 'provisioning' NOT NULL,
  "provider_vm_id" text,
  "provider_workspace_id" text,
  "provider_terminal_id" text,
  "owner_id" text NOT NULL,
  "idempotency_key" text NOT NULL,
  "request_digest" text NOT NULL,
  "failure_code" text,
  "failure_message" text,
  "version" integer DEFAULT 1 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_runtime_workspaces_lifecycle_check" CHECK ("lifecycle" in ('provisioning', 'running', 'suspended', 'stopped', 'failed')),
  CONSTRAINT "cloud_runtime_workspaces_provider_check" CHECK ("provider" in ('freestyle'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_runtime_workspaces_owner_idempotency_unique" ON "cloud_runtime_workspaces" ("owner_team_id", "idempotency_key");
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_runtime_workspaces_workspace_id_unique" ON "cloud_runtime_workspaces" ("workspace_id");
--> statement-breakpoint
CREATE INDEX "cloud_runtime_workspaces_owner_idx" ON "cloud_runtime_workspaces" ("owner_team_id", "updated_at");
