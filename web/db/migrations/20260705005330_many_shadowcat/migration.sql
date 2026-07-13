CREATE TABLE "vault_upload_grants" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"user_id" text NOT NULL,
	"object_key" text NOT NULL,
	"compressed_size_bytes" bigint NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "vault_upload_grants_object_key_unique" ON "vault_upload_grants" ("object_key");--> statement-breakpoint
CREATE INDEX "vault_upload_grants_user_idx" ON "vault_upload_grants" ("user_id");--> statement-breakpoint
CREATE INDEX "vault_upload_grants_expires_idx" ON "vault_upload_grants" ("expires_at");