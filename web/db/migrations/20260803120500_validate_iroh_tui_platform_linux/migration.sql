-- Validate the widened platform CHECK in its own migration (transaction), so
-- the scan runs under SHARE UPDATE EXCLUSIVE without blocking concurrent
-- writes. VALIDATE CONSTRAINT is idempotent on an already-valid constraint.
ALTER TABLE "iroh_endpoint_bindings"
  VALIDATE CONSTRAINT "iroh_endpoint_bindings_platform_check";
