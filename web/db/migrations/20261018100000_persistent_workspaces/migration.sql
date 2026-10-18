CREATE TABLE IF NOT EXISTS "persistent_workspaces" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "workspace_id" uuid NOT NULL,
  "tenant_id" text NOT NULL,
  "owner_id" text NOT NULL,
  "provider" text NOT NULL,
  "lifecycle" text DEFAULT 'provisioning' NOT NULL,
  "provider_vm_id" text,
  "provider_workspace_id" text,
  "provider_terminal_id" text,
  "idempotency_key" text NOT NULL,
  "request_digest" text NOT NULL,
  "workspace_name" text NOT NULL,
  "failure_code" text,
  "failure_message" text,
  "version" integer DEFAULT 1 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "persistent_workspaces_lifecycle_check" CHECK ("persistent_workspaces"."lifecycle" in ('provisioning', 'running', 'suspended', 'stopped', 'failed')),
  CONSTRAINT "persistent_workspaces_provider_check" CHECK ("persistent_workspaces"."provider" ~ '^[a-z][a-z0-9-]{1,63}$'),
  CONSTRAINT "persistent_workspaces_version_positive" CHECK ("persistent_workspaces"."version" > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS "persistent_workspaces_workspace_unique" ON "persistent_workspaces" USING btree ("workspace_id");
CREATE UNIQUE INDEX IF NOT EXISTS "persistent_workspaces_tenant_idempotency_unique" ON "persistent_workspaces" USING btree ("tenant_id", "idempotency_key");
CREATE INDEX IF NOT EXISTS "persistent_workspaces_owner_idx" ON "persistent_workspaces" USING btree ("owner_id", "updated_at");
