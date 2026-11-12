CREATE TABLE "coderouter_api_keys" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "stack_user_id" text NOT NULL,
  "key_hash" text NOT NULL,
  "key_prefix" text NOT NULL,
  "label" text DEFAULT 'default' NOT NULL,
  "last_used_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "coderouter_api_keys_hash_unique"
  ON "coderouter_api_keys" ("key_hash");
--> statement-breakpoint
CREATE INDEX "coderouter_api_keys_team_created_idx"
  ON "coderouter_api_keys" ("team_id", "created_at");
--> statement-breakpoint
CREATE INDEX "coderouter_api_keys_user_created_idx"
  ON "coderouter_api_keys" ("stack_user_id", "created_at");
