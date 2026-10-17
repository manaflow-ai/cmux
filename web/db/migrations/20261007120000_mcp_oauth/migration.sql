-- OAuth 2.1 for the cmux Cloud MCP server (ChatGPT and other MCP hosts).
-- Additive: no existing reader or writer uses these tables.
CREATE TABLE IF NOT EXISTS "mcp_oauth_clients" (
	"client_id" text PRIMARY KEY NOT NULL,
	"client_name" text,
	"redirect_uris" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "mcp_oauth_grants" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"client_id" text NOT NULL,
	"client_name" text,
	"stack_user_id" text NOT NULL,
	"team_id" text,
	"scopes" jsonb NOT NULL,
	"settings" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone,
	"revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "mcp_oauth_tokens" (
	"token_hash" text PRIMARY KEY NOT NULL,
	"grant_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"redirect_uri" text,
	"code_challenge" text,
	"expires_at" timestamp with time zone NOT NULL,
	"consumed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "mcp_oauth_tokens_grant_id_fk" FOREIGN KEY ("grant_id") REFERENCES "mcp_oauth_grants" ("id") ON DELETE CASCADE,
	CONSTRAINT "mcp_oauth_tokens_kind" CHECK ("kind" in ('code', 'access', 'refresh'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "mcp_oauth_grants_user_idx" ON "mcp_oauth_grants" USING btree ("stack_user_id","created_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "mcp_oauth_tokens_grant_idx" ON "mcp_oauth_tokens" USING btree ("grant_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "mcp_oauth_tokens_expires_idx" ON "mcp_oauth_tokens" USING btree ("expires_at");
