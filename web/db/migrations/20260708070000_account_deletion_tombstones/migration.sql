CREATE TABLE "account_deletion_tombstones" (
  "user_id_hash" text PRIMARY KEY NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
