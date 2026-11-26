DO $$
BEGIN
  IF to_regclass('public.run_artifacts') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_artifacts' AND column_name = 'payload'
  ) THEN
    ALTER TABLE "run_artifacts"
      ADD COLUMN "payload" jsonb NOT NULL DEFAULT '{}'::jsonb;
  ELSE
    UPDATE "run_artifacts" SET "payload" = '{}'::jsonb WHERE "payload" IS NULL;
    ALTER TABLE "run_artifacts"
      ALTER COLUMN "payload" SET DEFAULT '{}'::jsonb,
      ALTER COLUMN "payload" SET NOT NULL;
  END IF;

  -- Older Cloud deployments used these receipt columns. Keep them writable
  -- while the durable Run API uses its inline JSON payload contract.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_artifacts' AND column_name = 'uri'
  ) THEN
    ALTER TABLE "run_artifacts" ALTER COLUMN "uri" SET DEFAULT 'inline://cmux-run-artifact';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_artifacts' AND column_name = 'media_type'
  ) THEN
    ALTER TABLE "run_artifacts" ALTER COLUMN "media_type" SET DEFAULT 'application/json';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_artifacts' AND column_name = 'metadata'
  ) THEN
    ALTER TABLE "run_artifacts" ALTER COLUMN "metadata" SET DEFAULT '{}'::jsonb;
  END IF;
END $$;
