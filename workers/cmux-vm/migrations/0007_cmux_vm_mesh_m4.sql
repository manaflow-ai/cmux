-- cmux VM mesh experiment M4 (cx-0op.6, cx-0op.7). Inside the cmux_vm schema
-- only and additive: one nullable column on cmux_vm.audit_log, the action
-- CHECK on cmux_vm.audit_log replaced by a wider one, and two new tables.
-- Nothing else is dropped. No grants (the operator
-- grants the Worker role privileges on the new tables separately). Applied by
-- an operator (staging rehearsal first, in one transaction, e.g. psql -1),
-- never by the Worker. Needs 0001-0006.
--
-- Until it is applied the Worker still works: membership answers come from
-- Stack on every call (the cache is skipped when it cannot be read), audit rows
-- of device-signed actions go to the Worker log instead of the table, and the
-- Stack webhook answers 503 so Stack retries it.

-- Audit actions may contain '_' (device.rotate_key and enrollment_code.create, written since M2):
-- the old CHECK refused it, so those rows went to
-- the Worker log only. Every value the old CHECK accepted still passes.
ALTER TABLE cmux_vm.audit_log DROP CONSTRAINT IF EXISTS audit_log_action_check;
ALTER TABLE cmux_vm.audit_log ADD CONSTRAINT audit_log_action_check
  CHECK (action ~ '^[a-z][a-z._]{1,63}$');

-- Device-signed actions are audited as the device (actor 'device:<id>'); the
-- principal the device acts for goes here ('user:<id>' or 'key:<id>'). NULL for
-- every other row.
ALTER TABLE cmux_vm.audit_log
  ADD COLUMN IF NOT EXISTS owner_actor text NULL
    CHECK (owner_actor IS NULL OR char_length(owner_actor) BETWEEN 1 AND 160);

-- The shared positive Stack team-membership cache. member_asked_at is when the
-- Stack request that answered "member" was sent; it is trusted for 60 s and
-- never when revoked_at (the Stack team-membership webhook) is at or after it.
-- "Not a member" is never stored.
CREATE TABLE IF NOT EXISTS cmux_vm.stack_memberships (
  tenant_id       text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  user_id         text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
  member_asked_at timestamptz NULL,
  revoked_at      timestamptz NULL,
  PRIMARY KEY (tenant_id, user_id)
);

-- Stack webhook messages processed to the end, by message id (the same on
-- every retry of one event), so a retry does nothing twice.
CREATE TABLE IF NOT EXISTS cmux_vm.stack_webhook_deliveries (
  message_id   text        PRIMARY KEY CHECK (char_length(message_id) BETWEEN 1 AND 256),
  event_type   text        NOT NULL CHECK (event_type ~ '^[a-z_]{1,40}\.[a-z_]{1,40}$'),
  tenant_id    text        NULL CHECK (tenant_id IS NULL OR char_length(tenant_id) BETWEEN 1 AND 128),
  user_id      text        NULL CHECK (user_id IS NULL OR char_length(user_id) BETWEEN 1 AND 128),
  processed_at timestamptz NOT NULL DEFAULT now()
);
