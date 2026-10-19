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
-- 'e2b' and 'daytona' are compared as text on purpose, the same way the Blaxel
-- migration does it: on a fresh database every migration runs in one
-- transaction, and Postgres rejects an enum literal for a label that was added
-- by an earlier ALTER TYPE ... ADD VALUE in that transaction ("unsafe use of
-- new value"). 'daytona' is such a label. Today the Blaxel migration re-creates
-- the type just before this file runs, which is the only reason the literal
-- would resolve; the text comparison keeps this file correct on its own.
--
-- E2B and Daytona machines are unreachable regardless: both drivers are gone,
-- so nothing in the control plane can address them. Every machine on either
-- provider that is not already destroyed is marked destroyed here, the same
-- way markDestroyed does it at runtime, with failure_code 'provider_retired'
-- so the row says why. Reads already hide destroyed rows, and a base whose
-- active machine is destroyed opens a fresh generation on the default
-- provider, so those bases heal on their next open. The sandboxes themselves
-- must be deleted in the E2B and Daytona consoles; this migration only records
-- that they are gone.
--
-- The rows are then rewritten to 'freestyle' so the enum can be rebuilt
-- without dropping history (usage events, base generations). They are all
-- destroyed by then, so no read path will ever hand one to the Freestyle
-- driver.

UPDATE "cloud_vms"
SET
  "status" = 'destroyed',
  "destroyed_at" = COALESCE("destroyed_at", now()),
  "updated_at" = now(),
  "failure_code" = COALESCE("failure_code", 'provider_retired'),
  "failure_message" = COALESCE(
    "failure_message",
    CASE "provider"::text
      WHEN 'e2b' THEN 'E2B was retired as a Cloud VM provider; this machine can no longer be reached.'
      ELSE 'Daytona was retired as a Cloud VM provider; this machine can no longer be reached.'
    END
  )
WHERE "provider"::text IN ('e2b', 'daytona') AND "status" <> 'destroyed';

UPDATE "cloud_vms" SET "provider" = 'freestyle' WHERE "provider"::text IN ('e2b', 'daytona');
UPDATE "cloud_vm_usage_events" SET "provider" = 'freestyle' WHERE "provider"::text IN ('e2b', 'daytona');
UPDATE "cloud_vm_bases" SET "active_provider" = 'freestyle' WHERE "active_provider"::text IN ('e2b', 'daytona');
UPDATE "cloud_vm_base_generations" SET "provider" = 'freestyle' WHERE "provider"::text IN ('e2b', 'daytona');

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
