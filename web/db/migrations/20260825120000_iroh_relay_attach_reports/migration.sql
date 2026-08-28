ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "relay_attached_url" text;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "relay_attach_reported_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_relay_attached_url_check"
  CHECK ("relay_attached_url" IS NULL OR ("relay_attached_url" ~ '^https://' AND length("relay_attached_url") <= 2048));
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_relay_attach_reported_check"
  CHECK ("relay_attached_url" IS NULL OR "relay_attach_reported_at" IS NOT NULL);
