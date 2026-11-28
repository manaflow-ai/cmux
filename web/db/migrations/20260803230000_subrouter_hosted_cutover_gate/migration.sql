ALTER TABLE "subrouter_tenants"
  ADD COLUMN "hosted_finalization_started_at" timestamp with time zone,
  ADD COLUMN "hosted_ready_at" timestamp with time zone;
