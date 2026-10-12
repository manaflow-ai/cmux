-- cmux VM mesh experiment M4, G1 retries and user.deleted (cx-0op.6). Inside
-- the cmux_vm schema only and additive: one new table and one new index.
-- Nothing is dropped or changed. No grants (the operator grants the Worker
-- role privileges on the new table separately: SELECT, INSERT, UPDATE). Applied
-- by an operator (staging rehearsal first, in one transaction, e.g. psql -1),
-- never by the Worker. Needs 0001-0007.
--
-- Until it is applied the Stack webhook answers 503 for the events it acts on
-- (team_membership.deleted, user.deleted), so Stack retries them; nothing else
-- changes.

-- When a Stack webhook message (by its Svix message id, the same on every
-- retry) first reached the Worker. A retry is judged by this time, not by its
-- own: devices enrolled after it are never revoked by that message, and a
-- membership Stack confirmed after it skips the revocation (the user was added
-- back).
CREATE TABLE IF NOT EXISTS cmux_vm.stack_webhook_events (
  message_id    text        PRIMARY KEY CHECK (char_length(message_id) BETWEEN 1 AND 256),
  first_seen_at timestamptz NOT NULL
);

-- user.deleted finds the tenants where the user still has live devices.
CREATE INDEX IF NOT EXISTS mesh_devices_created_by_live
  ON cmux_vm.mesh_devices (created_by)
  WHERE deleted_at IS NULL;
