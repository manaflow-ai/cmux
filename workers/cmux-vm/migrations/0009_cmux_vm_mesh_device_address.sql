-- cmux VM mesh: a device's published public IPv6 address (bead cx-wb5.45,
-- transport.md sections 7 and 13.6). Inside the cmux_vm schema only and
-- additive: two nullable columns on cmux_vm.mesh_devices and a wider purpose
-- CHECK on cmux_vm.mesh_signed_requests that accepts every value the old one
-- did plus 'address' (the replay claim of a device publishing its address).
-- Nothing is dropped. No new table, so no new grant: the Worker role already
-- has SELECT and UPDATE on mesh_devices (key rotation) and INSERT on
-- mesh_signed_requests. Applied by an operator (staging rehearsal first, in
-- one transaction, e.g. psql -1), never by the Worker. Needs 0001-0008.
-- Existing rows have NULL in both columns and satisfy both CHECKs, so the
-- ALTERs only read the tables to validate them.
--
-- Until it is applied the schema gate answers 503 on every route but
-- /healthz (src/db/schema-check.ts names cmux_vm.mesh_devices.public_ipv6).
--
-- Rollback (in one transaction; deletes every published address, and the
-- Worker build that needs 0009 must be rolled back first or it answers 503):
--   ALTER TABLE cmux_vm.mesh_devices DROP COLUMN IF EXISTS public_ipv6, DROP COLUMN IF EXISTS public_ipv6_at;
--   DELETE FROM cmux_vm.mesh_signed_requests WHERE purpose = 'address';
--   ALTER TABLE cmux_vm.mesh_signed_requests DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_check;
--   ALTER TABLE cmux_vm.mesh_signed_requests ADD CONSTRAINT mesh_signed_requests_purpose_check
--     CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel'));
-- Address rules already created at the provider stay until the next reconcile
-- of their mesh under the rolled-back build; that build does not know them as
-- address rules, so delete them by exact id from cmux_vm.mesh_firewall_rules
-- rows whose rule_key contains ':from:' first.

-- The device's current global unicast IPv6 address, canonical text (the
-- Worker parses and normalizes it; this CHECK only keeps the column to a
-- plain IPv6 literal, never a prefix or zone). NULL: none published.
ALTER TABLE cmux_vm.mesh_devices
  ADD COLUMN IF NOT EXISTS public_ipv6 text NULL
    CONSTRAINT mesh_devices_public_ipv6_check CHECK (public_ipv6 IS NULL OR public_ipv6 ~ '^[0-9a-f:]{2,39}$'),
  ADD COLUMN IF NOT EXISTS public_ipv6_at timestamptz NULL;

ALTER TABLE cmux_vm.mesh_signed_requests DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_check;
ALTER TABLE cmux_vm.mesh_signed_requests ADD CONSTRAINT mesh_signed_requests_purpose_check
  CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel', 'address'));
