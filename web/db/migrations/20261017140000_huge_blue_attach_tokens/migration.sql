ALTER TABLE "cloud_runtime_workspaces" DROP CONSTRAINT "cloud_runtime_workspaces_provider_check";
ALTER TABLE "cloud_runtime_workspaces" ADD CONSTRAINT "cloud_runtime_workspaces_provider_check" CHECK (provider IN ('freestyle', 'huge-blue'));
CREATE TABLE "huge_blue_attach_tokens" (
  "token_hash" text PRIMARY KEY,
  "runtime_id" uuid NOT NULL REFERENCES "cloud_runtime_workspaces" ("runtime_id") ON DELETE CASCADE,
  "owner_id" text NOT NULL,
  "tenant_id" text NOT NULL,
  "host_id" text NOT NULL,
  "session" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "revoked_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX "huge_blue_attach_tokens_runtime_idx" ON "huge_blue_attach_tokens" ("runtime_id");
