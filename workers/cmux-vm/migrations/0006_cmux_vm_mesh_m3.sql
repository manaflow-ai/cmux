-- cmux VM mesh experiment M3 (cx-0op.5): device-signed requests. Inside the
-- cmux_vm schema only. Additive: the purpose CHECK on
-- cmux_vm.mesh_signed_requests is replaced by a wider one that accepts every
-- value the old one did ('enroll', 'rotate-key') plus 'peers' and 'tunnel', the
-- replay claims of a device reading its own peer map and tunnel config with its
-- install-key signature. Nothing else changes: no table, column or index is
-- added or dropped, so no new table needs a grant. Applied by an operator
-- (staging rehearsal first, in one transaction like 0004, e.g. psql -1), never
-- by the Worker. Needs 0001-0005. Existing rows all satisfy the new CHECK, so
-- validating it only reads the small, pruned table.

ALTER TABLE cmux_vm.mesh_signed_requests DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_check;
ALTER TABLE cmux_vm.mesh_signed_requests ADD CONSTRAINT mesh_signed_requests_purpose_check
  CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel'));
