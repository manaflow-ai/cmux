ALTER TABLE "vault_upload_grants" ADD COLUMN "reservation_token" uuid DEFAULT gen_random_uuid() NOT NULL;
