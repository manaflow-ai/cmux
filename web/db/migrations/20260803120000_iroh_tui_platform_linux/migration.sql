-- Allow headless cmux-tui session servers to register iroh endpoint bindings.
-- The re-added constraint is NOT VALID so the ACCESS EXCLUSIVE lock taken by
-- the DDL never waits on a full-table validation scan; the follow-up
-- migration (20260803120500) validates it under a weaker lock, mirroring
-- 20260730210000/20260730211000_connectivity_route_revision. The new
-- constraint is strictly weaker than the old one ('mac', 'ios'), so every
-- existing row already satisfies it and validation cannot fail.
ALTER TABLE "iroh_endpoint_bindings"
  DROP CONSTRAINT "iroh_endpoint_bindings_platform_check";
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_platform_check"
  CHECK ("platform" in ('mac', 'ios', 'linux')) NOT VALID;
