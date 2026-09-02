-- Remove 'blaxel' from vm_provider.
--
-- Postgres cannot drop a value from an enum, so the type is rebuilt: rename the
-- old one aside, create the new one without 'blaxel', re-point every column
-- then drop the old type. (No provider column carries a default.) The DROP TYPE
-- at the end is the safety interlock: it fails if anything still references the
-- old type, so a missed column aborts the whole transaction instead of silently
-- leaving a split schema.
--
-- Any row still naming a Blaxel machine is rewritten to 'e2b' first. Those
-- machines are unreachable regardless (the driver is gone); this keeps history
-- rows readable rather than dropping them. Run the reaper to destroy live
-- Blaxel machines BEFORE applying this migration — afterwards nothing in the
-- control plane can address them.

UPDATE "cloud_vms" SET "provider" = 'e2b' WHERE "provider" = 'blaxel';
UPDATE "cloud_vm_usage_events" SET "provider" = 'e2b' WHERE "provider" = 'blaxel';
UPDATE "cloud_vm_bases" SET "active_provider" = 'e2b' WHERE "active_provider" = 'blaxel';
UPDATE "cloud_vm_base_generations" SET "provider" = 'e2b' WHERE "provider" = 'blaxel';

ALTER TYPE "vm_provider" RENAME TO "vm_provider_old";
CREATE TYPE "vm_provider" AS ENUM ('e2b', 'freestyle', 'daytona');

ALTER TABLE "cloud_vms"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_usage_events"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_bases"
  ALTER COLUMN "active_provider" TYPE "vm_provider" USING "active_provider"::text::"vm_provider";
ALTER TABLE "cloud_vm_base_generations"
  ALTER COLUMN "provider" TYPE "vm_provider" USING "provider"::text::"vm_provider";

DROP TYPE "vm_provider_old";
