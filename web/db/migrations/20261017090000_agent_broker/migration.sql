CREATE TABLE "agent_broker_jobs" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "tenant_id" text NOT NULL,
  "effect_key" text NOT NULL,
  "request_digest" text NOT NULL,
  "owner" text NOT NULL,
  "source_sha" text NOT NULL,
  "scope_revision" text NOT NULL,
  "host_class" text NOT NULL,
  "payload" jsonb NOT NULL,
  "status" text DEFAULT 'queued' NOT NULL,
  "attempt" integer DEFAULT 0 NOT NULL,
  "lease_token" uuid,
  "lease_generation" integer DEFAULT 0 NOT NULL,
  "lease_owner" text,
  "lease_expires_at" timestamp with time zone,
  "receipt_sequence" integer DEFAULT 0 NOT NULL,
  "result" jsonb,
  "error" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "completed_at" timestamp with time zone,
  CONSTRAINT "agent_broker_jobs_status_check" CHECK ("status" in ('queued', 'leased', 'completed', 'failed')),
  CONSTRAINT "agent_broker_jobs_attempt_check" CHECK ("attempt" >= 0),
  CONSTRAINT "agent_broker_jobs_lease_generation_check" CHECK ("lease_generation" >= 0),
  CONSTRAINT "agent_broker_jobs_receipt_sequence_check" CHECK ("receipt_sequence" >= 0),
  CONSTRAINT "agent_broker_jobs_lease_pair_check" CHECK (("lease_token" is null) = ("lease_expires_at" is null))
);
CREATE UNIQUE INDEX "agent_broker_jobs_tenant_effect_unique" ON "agent_broker_jobs" ("tenant_id", "effect_key");
CREATE INDEX "agent_broker_jobs_claim_idx" ON "agent_broker_jobs" ("status", "lease_expires_at", "created_at");
CREATE INDEX "agent_broker_jobs_tenant_updated_idx" ON "agent_broker_jobs" ("tenant_id", "updated_at", "id");

CREATE TABLE "agent_broker_receipts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "job_id" uuid NOT NULL REFERENCES "agent_broker_jobs"("id") ON DELETE CASCADE,
  "sequence" integer NOT NULL,
  "state" text NOT NULL,
  "attempt" integer NOT NULL,
  "lease_generation" integer NOT NULL,
  "owner" text NOT NULL,
  "host_class" text NOT NULL,
  "effect_key" text NOT NULL,
  "result" jsonb,
  "error" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "agent_broker_receipts_sequence_check" CHECK ("sequence" > 0),
  CONSTRAINT "agent_broker_receipts_state_check" CHECK ("state" in ('queued', 'leased', 'completed', 'failed')),
  CONSTRAINT "agent_broker_receipts_attempt_check" CHECK ("attempt" >= 0),
  CONSTRAINT "agent_broker_receipts_lease_generation_check" CHECK ("lease_generation" >= 0)
);
CREATE UNIQUE INDEX "agent_broker_receipts_job_sequence_unique" ON "agent_broker_receipts" ("job_id", "sequence");
CREATE INDEX "agent_broker_receipts_job_cursor_idx" ON "agent_broker_receipts" ("job_id", "sequence");
