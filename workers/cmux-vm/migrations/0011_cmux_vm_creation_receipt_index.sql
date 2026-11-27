-- Concurrent index build runs outside a migration transaction; the release runner owns its receipt.
-- Reused keys retain multiple allocations. Lookup selects the newest, while an active journal takes precedence.
CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_creation_key_idx ON cmux_vm.resources (tenant_id, creation_key, created_at DESC, cmux_id DESC) WHERE creation_key IS NOT NULL;
