ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "direct_port_v4" integer;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "direct_port_v6" integer;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_direct_port_v4_check"
  CHECK ("direct_port_v4" IS NULL OR "direct_port_v4" BETWEEN 1 AND 65535);
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_direct_port_v6_check"
  CHECK ("direct_port_v6" IS NULL OR "direct_port_v6" BETWEEN 1 AND 65535);
