-- Backfill once; subsequent audit capacity checks read the singleton counter.
CREATE TABLE "authority_audit_usage" (
  "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
  "row_count" INTEGER NOT NULL CHECK ("row_count" BETWEEN 0 AND 65536)
);
--> statement-breakpoint
INSERT INTO "authority_audit_usage" ("id", "row_count") SELECT 1, count(*) FROM "authority_audit";
--> statement-breakpoint
DROP TRIGGER "authority_audit_limit_guard";
--> statement-breakpoint
CREATE TRIGGER "authority_audit_limit_guard" BEFORE INSERT ON "authority_audit"
WHEN (SELECT "row_count" FROM "authority_audit_usage" WHERE "id" = 1) >= 65536
BEGIN SELECT RAISE(ABORT, 'audit_limit'); END;
--> statement-breakpoint
CREATE TRIGGER "authority_audit_insert_count" AFTER INSERT ON "authority_audit"
BEGIN UPDATE "authority_audit_usage" SET "row_count" = "row_count" + 1 WHERE "id" = 1; END;
--> statement-breakpoint
CREATE TRIGGER "authority_audit_delete_count" AFTER DELETE ON "authority_audit"
BEGIN UPDATE "authority_audit_usage" SET "row_count" = "row_count" - 1 WHERE "id" = 1; END;
--> statement-breakpoint
UPDATE "team_meta" SET "schema_version" = 7 WHERE "id" = 1;
