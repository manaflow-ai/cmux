ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "endpoint_record" text;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "endpoint_record_updated_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_endpoint_record_check"
  CHECK ("endpoint_record" IS NULL OR ("endpoint_record" ~ '^[A-Za-z0-9+/]+={0,2}$' AND length("endpoint_record") <= 1600));
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_endpoint_record_updated_check"
  CHECK ("endpoint_record" IS NULL OR "endpoint_record_updated_at" IS NOT NULL);
