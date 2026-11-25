-- Usage statements for the cmux Cloud $1 pass (RFD 0052): one record per statement day (21, 27, 30),
-- written under the pass lock before the email goes out, so each statement is sent at most once.
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "statements" jsonb DEFAULT '{}'::jsonb NOT NULL;
