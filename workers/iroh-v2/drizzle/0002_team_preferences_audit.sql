-- Team relay preferences and durable authority audit records.
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "team_preferences" (
  "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
  "relay_urls_json" TEXT NOT NULL,
  "revision" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "authority_audit" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "event_type" TEXT NOT NULL,
  "actor_user_id" TEXT NOT NULL,
  "target_id" TEXT NOT NULL,
  "revision" INTEGER NOT NULL,
  "created_at" INTEGER NOT NULL,
  "detail_json" TEXT NOT NULL CHECK (length("detail_json") <= 16384)
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "authority_audit_target_idx" ON "authority_audit" ("target_id", "created_at");
