-- Remove 'blaxel' from vm_provider.
--
-- Postgres cannot drop a value from an enum, so the type is rebuilt: rename the
-- old one aside, create the new one without 'blaxel', re-point every column
-- then drop the old type. (No provider column carries a default.) The DROP TYPE
-- at the end is the safety interlock: it fails if anything still references the
-- old type, so a missed column aborts the whole transaction instead of silently
-- leaving a split schema.
--
-- 'blaxel' is compared as text on purpose: on a fresh database the label was
-- added by an earlier migration in the same transaction, and Postgres rejects
-- an enum literal for a label that is not yet committed ("unsafe use of new
-- value"). The text comparison reads the same rows without that lookup.
--
-- Blaxel machines are unreachable regardless: the driver is gone, so nothing
-- in the control plane can address them. Every Blaxel machine that is not
-- already destroyed is marked destroyed here, the same way markDestroyed does
-- it at runtime, with failure_code 'provider_retired' so the row says why.
-- Reads already hide destroyed rows, and a base whose active machine is
-- destroyed opens a fresh generation on the default provider, so those bases
-- heal on their next open. The sandboxes themselves must be deleted in the
-- Blaxel console; this migration only records that they are gone.
--
-- The rows are then rewritten to 'e2b' so the enum can be rebuilt without
-- dropping history (usage events, base generations). They are all destroyed
-- by then, so no read path will ever hand one to the e2b driver.

UPDATE "cloud_vms"
SET
  "status" = 'destroyed',
  "destroyed_at" = COALESCE("destroyed_at", now()),
  "updated_at" = now(),
  "failure_code" = COALESCE("failure_code", 'provider_retired'),
  "failure_message" = COALESCE(
    "failure_message",
    'Blaxel was retired as a Cloud VM provider; this machine can no longer be reached.'
  )
WHERE "provider"::text = 'blaxel' AND "status" <> 'destroyed';

UPDATE "cloud_vms" SET "provider" = 'e2b' WHERE "provider"::text = 'blaxel';
UPDATE "cloud_vm_usage_events" SET "provider" = 'e2b' WHERE "provider"::text = 'blaxel';
UPDATE "cloud_vm_bases" SET "active_provider" = 'e2b' WHERE "active_provider"::text = 'blaxel';
UPDATE "cloud_vm_base_generations" SET "provider" = 'e2b' WHERE "provider"::text = 'blaxel';

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
