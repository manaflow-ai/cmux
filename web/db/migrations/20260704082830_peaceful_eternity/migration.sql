CREATE TABLE "vault_cli_auth_requests" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"device_code_hash" text NOT NULL,
	"user_code" text NOT NULL,
	"status" text NOT NULL,
	"user_id" text,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "vault_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"user_id" text NOT NULL,
	"agent" text NOT NULL,
	"agent_session_id" text NOT NULL,
	"rel_path" text NOT NULL,
	"cwd" text,
	"latest_sha256" text NOT NULL,
	"latest_object_key" text NOT NULL,
	"size_bytes" bigint NOT NULL,
	"compressed_size_bytes" bigint,
	"first_uploaded_at" timestamp with time zone NOT NULL,
	"last_uploaded_at" timestamp with time zone NOT NULL,
	"metadata" jsonb
);
--> statement-breakpoint
CREATE TABLE "vault_snapshots" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"session_id" uuid NOT NULL,
	"sha256" text NOT NULL,
	"object_key" text NOT NULL,
	"size_bytes" bigint NOT NULL,
	"compressed_size_bytes" bigint NOT NULL,
	"uploaded_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "vault_cli_auth_requests_device_hash_unique" ON "vault_cli_auth_requests" ("device_code_hash");--> statement-breakpoint
CREATE INDEX "vault_cli_auth_requests_expires_idx" ON "vault_cli_auth_requests" ("expires_at");--> statement-breakpoint
CREATE INDEX "vault_cli_auth_requests_user_code_idx" ON "vault_cli_auth_requests" ("user_code");--> statement-breakpoint
CREATE UNIQUE INDEX "vault_sessions_user_agent_session_unique" ON "vault_sessions" ("user_id","agent","agent_session_id");--> statement-breakpoint
CREATE INDEX "vault_sessions_user_last_uploaded_idx" ON "vault_sessions" ("user_id","last_uploaded_at");--> statement-breakpoint
CREATE UNIQUE INDEX "vault_snapshots_session_sha_unique" ON "vault_snapshots" ("session_id","sha256");--> statement-breakpoint
ALTER TABLE "vault_snapshots" ADD CONSTRAINT "vault_snapshots_session_id_vault_sessions_id_fkey" FOREIGN KEY ("session_id") REFERENCES "vault_sessions"("id") ON DELETE CASCADE;