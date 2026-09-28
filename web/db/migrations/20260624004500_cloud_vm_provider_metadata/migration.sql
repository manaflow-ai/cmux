ALTER TABLE "cloud_vms" ADD COLUMN "provider_metadata" jsonb DEFAULT '{}'::jsonb NOT NULL;
