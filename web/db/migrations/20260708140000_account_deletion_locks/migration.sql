CREATE TABLE "account_deletion_tombstones" (
  "user_id_hash" text PRIMARY KEY NOT NULL,
  "user_id" text,
  "status" text DEFAULT 'pending' NOT NULL,
  "attempt_count" integer DEFAULT 0 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "started_at" timestamp with time zone,
  "completed_at" timestamp with time zone,
  "error_message" text
);

CREATE INDEX "account_deletion_tombstones_status_updated_idx"
  ON "account_deletion_tombstones" ("status", "updated_at");
CREATE INDEX "account_deletion_tombstones_user_idx"
  ON "account_deletion_tombstones" ("user_id");
