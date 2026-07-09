-- Env layer cache for `cmux vm env build`: maps a chain hash (provider + base
-- image + ordered spec steps) to the provider snapshot taken after that step.
-- Team-scoped; snapshots can contain secrets so rows are never shared.
CREATE TABLE IF NOT EXISTS "cloud_vm_env_layers" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"user_id" text NOT NULL,
	"billing_team_id" text NOT NULL,
	"provider" "vm_provider" NOT NULL,
	"base_image_id" text NOT NULL,
	"chain_hash" text NOT NULL,
	"step_index" integer NOT NULL,
	"step_name" text,
	"spec_digest" text NOT NULL,
	"snapshot_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone DEFAULT now() NOT NULL,
	"invalidated_at" timestamp with time zone
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_env_layers_team_provider_chain_unique" ON "cloud_vm_env_layers" ("billing_team_id","provider","chain_hash") WHERE "invalidated_at" is null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_env_layers_team_spec_idx" ON "cloud_vm_env_layers" ("billing_team_id","spec_digest");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_env_layers_last_used_idx" ON "cloud_vm_env_layers" ("last_used_at");
