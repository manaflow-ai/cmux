CREATE TABLE "vault_upload_tombstones" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "object_key" text NOT NULL,
  "upload_object_key" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "vault_upload_tombstones_user_idx" ON "vault_upload_tombstones" ("user_id");
--> statement-breakpoint
CREATE INDEX "vault_upload_tombstones_expires_idx" ON "vault_upload_tombstones" ("expires_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "vault_upload_tombstones_upload_object_key_unique" ON "vault_upload_tombstones" ("upload_object_key");
