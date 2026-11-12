CREATE TABLE "iroh_v2_endpoint_owners" (
  "endpoint_id" varchar(64) PRIMARY KEY CHECK (endpoint_id ~ '^[0-9a-f]{64}$'),
  "identity_hash" varchar(64) NOT NULL CHECK (identity_hash ~ '^[0-9a-f]{64}$'),
  "environment" varchar(128) NOT NULL,
  "project_id" varchar(128) NOT NULL,
  "team_id" varchar(128) NOT NULL,
  "user_id" varchar(128) NOT NULL,
  "identity_json" text NOT NULL CHECK (octet_length(identity_json) <= 16384),
  "created_at" bigint NOT NULL CHECK (created_at >= 0)
);
CREATE INDEX "iroh_v2_endpoint_owners_user" ON "iroh_v2_endpoint_owners" ("environment", "project_id", "user_id");
CREATE TABLE "iroh_v2_owner_budgets" (
  "user_scope_hash" varchar(64) PRIMARY KEY CHECK (user_scope_hash ~ '^[0-9a-f]{64}$'),
  "owner_count" bigint NOT NULL DEFAULT 0 CHECK (owner_count BETWEEN 0 AND 4096)
);
