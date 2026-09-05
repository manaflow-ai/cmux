ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "app_version" text;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_app_version_check"
  CHECK ("app_version" IS NULL OR (length("app_version") BETWEEN 1 AND 64 AND "app_version" !~ '[[:cntrl:]]'));
