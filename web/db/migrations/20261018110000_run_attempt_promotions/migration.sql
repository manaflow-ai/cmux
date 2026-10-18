CREATE TABLE IF NOT EXISTS "run_attempt_promotions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid NOT NULL REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "request_key" text NOT NULL,
  "claim_id" uuid NOT NULL,
  "status" text DEFAULT 'reserved' NOT NULL,
  "promotion" jsonb,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "run_attempt_promotions_status_check" CHECK ("status" in ('reserved', 'completed'))
);
CREATE UNIQUE INDEX IF NOT EXISTS "run_attempt_promotions_user_request_unique"
  ON "run_attempt_promotions" USING btree ("user_id", "request_key");
CREATE UNIQUE INDEX IF NOT EXISTS "run_attempt_promotions_user_attempt_unique"
  ON "run_attempt_promotions" USING btree ("user_id", "attempt_id");
CREATE INDEX IF NOT EXISTS "run_attempt_promotions_status_updated_idx"
  ON "run_attempt_promotions" USING btree ("status", "updated_at");
