-- Remove 'e2b' and 'daytona' from vm_provider, leaving Freestyle as the only
-- Cloud VM provider.
--
-- Postgres cannot drop a value from an enum, so the type is rebuilt: rename the
-- old one aside, create the new one with only 'freestyle', re-point every column
-- then drop the old type. (No provider column carries a default.) The DROP TYPE
-- at the end is the safety interlock: it fails if anything still references the
-- old type, so a missed column aborts the whole transaction instead of silently
-- leaving a split schema.
--
-- Rows still naming an E2B or Daytona machine are rewritten to 'freestyle'
-- first. Those machines are unreachable regardless (both drivers are gone);
-- this keeps history and usage rows readable rather than dropping them, at the
-- cost of mislabelling their provider. Destroy live E2B and Daytona machines
-- BEFORE applying this migration — afterwards nothing in the control plane can
-- address them.

UPDATE "cloud_vms" SET "provider" = 'freestyle' WHERE "provider" IN ('e2b', 'daytona');
UPDATE "cloud_vm_usage_events" SET "provider" = 'freestyle' WHERE "provider" IN ('e2b', 'daytona');
UPDATE "cloud_vm_bases" SET "active_provider" = 'freestyle' WHERE "active_provider" IN ('e2b', 'daytona');
UPDATE "cloud_vm_base_generations" SET "provider" = 'freestyle' WHERE "provider" IN ('e2b', 'daytona');

ALTER TYPE "vm_provider" RENAME TO "vm_provider_old";
CREATE TYPE "vm_provider" AS ENUM ('freestyle');

ALTER TABLE "cloud_vms"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_usage_events"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_bases"
  ALTER COLUMN "active_provider" TYPE "vm_provider" USING "active_provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_base_generations"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";

DROP TYPE "vm_provider_old";
