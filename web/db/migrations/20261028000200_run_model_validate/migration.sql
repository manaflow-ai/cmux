-- Validates what 20261028000100_run_model_expand added NOT VALID, in a migration of its own.
-- The one row change: a run_attempts.runtime_id that points at no cloud_runtimes row (main's column
-- had no FK) becomes NULL, which is what the FK's ON DELETE SET NULL would have done. The attempt row
-- itself is kept.
UPDATE "run_attempts" AS attempt SET "runtime_id" = NULL
WHERE attempt."runtime_id" IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM "cloud_runtimes" AS runtime WHERE runtime."id" = attempt."runtime_id");--> statement-breakpoint
ALTER TABLE "run_attempts" VALIDATE CONSTRAINT "run_attempts_lease_generation_check";--> statement-breakpoint
-- The runtime_id FK, where it is not validated yet: the expand step's. next's inline FK is already valid.
DO $$
DECLARE
  fk text;
BEGIN
  FOR fk IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = '"run_attempts"'::regclass AND contype = 'f' AND NOT convalidated
      AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = '"run_attempts"'::regclass AND attname = 'runtime_id')]
  LOOP
    EXECUTE format('ALTER TABLE "run_attempts" VALIDATE CONSTRAINT %I', fk);
  END LOOP;
END $$;--> statement-breakpoint
ALTER TABLE "run_artifacts" VALIDATE CONSTRAINT "run_artifacts_size_check";--> statement-breakpoint
ALTER TABLE "run_artifacts" VALIDATE CONSTRAINT "run_artifacts_digest_check";
