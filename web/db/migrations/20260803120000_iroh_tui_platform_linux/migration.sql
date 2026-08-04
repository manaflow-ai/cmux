-- Allow headless cmux-tui session servers to register iroh endpoint bindings.
-- The new constraint is strictly weaker than the old one ('mac', 'ios'), so
-- every existing row already satisfies it and the validation scan is a no-op
-- rewrite-free pass over a small table.
ALTER TABLE "iroh_endpoint_bindings"
  DROP CONSTRAINT "iroh_endpoint_bindings_platform_check";
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_platform_check"
  CHECK ("platform" in ('mac', 'ios', 'linux'));
