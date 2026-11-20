-- GCP is an explicit Labs provider; Freestyle remains the default.
ALTER TYPE "vm_provider" ADD VALUE IF NOT EXISTS 'gcp';

ALTER TABLE "cloud_runtime_workspaces" DROP CONSTRAINT IF EXISTS "cloud_runtime_workspaces_provider_check";
ALTER TABLE "cloud_runtime_workspaces"
  ADD CONSTRAINT "cloud_runtime_workspaces_provider_check" CHECK ("provider" in ('freestyle', 'gcp'));
