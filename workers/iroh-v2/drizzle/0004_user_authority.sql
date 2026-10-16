CREATE TABLE IF NOT EXISTS "user_authority" (
  "user_id" TEXT PRIMARY KEY NOT NULL,
  "verified_at" INTEGER NOT NULL,
  "expires_at" INTEGER NOT NULL,
  CHECK ("expires_at" = "verified_at" + 3600),
  CHECK (length(CAST("user_id" AS BLOB)) BETWEEN 1 AND 512)
);
CREATE TRIGGER IF NOT EXISTS "user_authority_limit_guard"
BEFORE INSERT ON "user_authority"
WHEN (SELECT count(*) FROM "user_authority") >= 4096
  AND NOT EXISTS (SELECT 1 FROM "user_authority" WHERE "user_id" = NEW."user_id")
BEGIN SELECT RAISE(ABORT, 'authority_limit'); END;
UPDATE "team_meta" SET "schema_version" = 5 WHERE "id" = 1;
