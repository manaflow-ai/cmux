CREATE TABLE IF NOT EXISTS "cloud_vm_publication_api_keys" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "publication_id" uuid NOT NULL REFERENCES "cloud_vm_publications" ("id") ON DELETE CASCADE,
  "owner_user_id" text NOT NULL,
  "name" text NOT NULL,
  "token_hash" text NOT NULL,
  "token_hint" text NOT NULL,
  "expires_at" timestamptz,
  "revoked_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "cloud_vm_publication_api_keys_hash_check" CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "cloud_vm_publication_api_keys_name_check" CHECK (char_length(name) BETWEEN 1 AND 64),
  CONSTRAINT "cloud_vm_publication_api_keys_hint_check" CHECK (char_length(token_hint) = 4)
);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_publication_api_keys_token_hash_unique" ON "cloud_vm_publication_api_keys" ("token_hash");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_publication_api_keys_publication_idx" ON "cloud_vm_publication_api_keys" ("publication_id", "created_at");
