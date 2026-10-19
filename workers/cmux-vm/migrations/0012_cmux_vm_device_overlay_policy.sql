-- contract: widens signed-request purposes; all old writes remain valid
-- Rehearse on staging and apply before deploying the build that needs 0012.
-- One ALTER atomically replaces the check, including on a repeated application.
-- No rows, privileges or credentials change. The named validated constraint
-- is checked by both the Worker schema gate and release tooling.
ALTER TABLE cmux_vm.mesh_signed_requests
  DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_check,
  DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_v2_check,
  ADD CONSTRAINT mesh_signed_requests_purpose_v2_check
    CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel', 'address', 'overlay-policy'));

-- Roll back the Worker first. Keep the wider constraint while any build may
-- still issue overlay-policy requests; shrinking it is not needed for rollback.
