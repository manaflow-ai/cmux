ALTER TABLE "run_attempts"
  ADD COLUMN "variant" jsonb;
--> statement-breakpoint
UPDATE "run_attempts"
SET "variant" = jsonb_build_object(
  'id', concat('attempt-', "ordinal" + 1),
  'label', concat('Attempt ', chr(65 + "ordinal")),
  'instruction', 'Explore the shared intent independently and publish build, test, and artifact evidence.'
)
WHERE "variant" IS NULL;
--> statement-breakpoint
ALTER TABLE "run_attempts"
  ALTER COLUMN "variant" SET NOT NULL;
