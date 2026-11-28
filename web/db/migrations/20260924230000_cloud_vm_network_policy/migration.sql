ALTER TABLE "cloud_vms"
  ADD COLUMN "network_policy" jsonb,
  ADD COLUMN "network_policy_status" jsonb;
