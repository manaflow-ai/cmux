-- Concurrent index build runs outside a migration transaction; the release runner owns its receipt.
-- A VM's live client sessions, revoked when the VM is deleted.
CREATE INDEX CONCURRENTLY IF NOT EXISTS vm_client_sessions_vm_idx ON cmux_vm.vm_client_sessions (tenant_id, vm_cmux_id) WHERE revoked_at IS NULL;
