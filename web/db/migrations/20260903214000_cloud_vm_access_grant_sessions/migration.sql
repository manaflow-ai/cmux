-- One physical Mac can use several cmux bundles, each with its own Stack login.
-- Remote Mac revoke must revoke every login session associated with the grant.

CREATE TABLE IF NOT EXISTS "cloud_vm_access_grant_sessions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "access_grant_id" uuid NOT NULL,
  "user_id" text NOT NULL,
  "stack_session_id" text NOT NULL,
  "session_issued_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_access_grant_sessions_access_grant_id_cloud_vm_access_grants_id_fk"
    FOREIGN KEY ("access_grant_id") REFERENCES "cloud_vm_access_grants"("id") ON DELETE cascade
);

CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_access_grant_sessions_grant_session_unique"
  ON "cloud_vm_access_grant_sessions" ("access_grant_id", "stack_session_id");
CREATE INDEX IF NOT EXISTS "cloud_vm_access_grant_sessions_user_session_idx"
  ON "cloud_vm_access_grant_sessions" ("user_id", "stack_session_id");

-- Preserve the latest session captured by the first access-grant migration.
INSERT INTO "cloud_vm_access_grant_sessions" (
  "access_grant_id", "user_id", "stack_session_id", "session_issued_at"
)
SELECT "id", "user_id", "stack_session_id", "created_at"
FROM "cloud_vm_access_grants"
WHERE "stack_session_id" IS NOT NULL
ON CONFLICT ("access_grant_id", "stack_session_id") DO NOTHING;

DROP INDEX IF EXISTS "cloud_vm_access_grants_session_idx";
ALTER TABLE "cloud_vm_access_grants" DROP COLUMN IF EXISTS "stack_session_id";
