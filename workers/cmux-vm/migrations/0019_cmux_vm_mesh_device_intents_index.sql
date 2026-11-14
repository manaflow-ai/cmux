-- Concurrent index build runs outside a migration transaction; the release runner owns its receipt.
-- A device's delete revokes its enroll intent (0018) by device id.
CREATE INDEX CONCURRENTLY IF NOT EXISTS mesh_device_intents_device_idx ON cmux_vm.mesh_device_intents (tenant_id, device_cmux_id) WHERE device_cmux_id IS NOT NULL;
