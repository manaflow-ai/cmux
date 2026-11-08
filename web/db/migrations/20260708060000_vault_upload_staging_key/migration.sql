ALTER TABLE "vault_upload_grants" ADD COLUMN "upload_object_key" text;--> statement-breakpoint
UPDATE "vault_upload_grants" SET "upload_object_key" = "object_key";--> statement-breakpoint
ALTER TABLE "vault_upload_grants" ALTER COLUMN "upload_object_key" SET NOT NULL;
