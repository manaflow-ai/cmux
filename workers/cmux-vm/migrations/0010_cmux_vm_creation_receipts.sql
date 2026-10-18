-- contract: validates nullable creation receipt CHECKs on existing ownership rows; all old rows remain valid
-- Apply in staging before the Worker, then production. No backfill or new privileges are required.
-- Rollback the Worker first; retain these additive columns and index so old allocation receipts survive.
-- Raw keys and provider evidence never enter this table.
ALTER TABLE cmux_vm.resources ADD COLUMN IF NOT EXISTS creation_key TEXT
  CONSTRAINT resources_creation_key_check CHECK (creation_key IS NULL OR (kind = 'vm' AND creation_key ~ '^[0-9a-f]{64}$'));
ALTER TABLE cmux_vm.resources ADD COLUMN IF NOT EXISTS creation_receipt JSONB
  CONSTRAINT resources_creation_receipt_check CHECK (
    (creation_key IS NULL AND creation_receipt IS NULL) OR
    (creation_key IS NOT NULL AND creation_receipt IS NOT NULL AND jsonb_typeof(creation_receipt) = 'object' AND creation_receipt ->> 'id' = cmux_id)
  );
-- A caller may reuse a key after retention. The newest allocation wins; an active journal takes precedence.
CREATE INDEX IF NOT EXISTS resources_creation_key_idx ON cmux_vm.resources (tenant_id, creation_key, created_at DESC, cmux_id DESC) WHERE creation_key IS NOT NULL;
