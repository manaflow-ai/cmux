ALTER TABLE "run_attempts"
  ADD COLUMN IF NOT EXISTS "variant" jsonb;

UPDATE "run_attempts"
SET "variant" = '{}'::jsonb
WHERE "variant" IS NULL;

ALTER TABLE "run_attempts"
  ALTER COLUMN "variant" SET NOT NULL;
