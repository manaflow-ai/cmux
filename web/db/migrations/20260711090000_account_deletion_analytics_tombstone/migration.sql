ALTER TABLE "account_deletion_tombstones"
  ADD COLUMN "analytics_deleted_at" timestamp with time zone;

CREATE TABLE "account_analytics_forward_leases" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "operation_id" uuid NOT NULL,
  "user_id_hash" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone NOT NULL
);

CREATE INDEX "account_analytics_forward_leases_user_expiry_idx"
  ON "account_analytics_forward_leases" USING btree ("user_id_hash", "expires_at");
CREATE INDEX "account_analytics_forward_leases_expiry_idx"
  ON "account_analytics_forward_leases" USING btree ("expires_at");
CREATE INDEX "account_analytics_forward_leases_operation_idx"
  ON "account_analytics_forward_leases" USING btree ("operation_id");
