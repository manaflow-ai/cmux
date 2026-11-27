-- cmux VM S2: VM display names and labels, and the audit log. Additive only:
-- two new columns on cmux_vm.resources (one nullable, one with a default) and
-- one new table with its index; nothing existing is altered or dropped. Applied by an operator (staging rehearsal
-- first), never by the Worker.

ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS display_name text NULL
  CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 100);

-- Key/value labels for finding VMs; the API validates keys and values.
ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS labels jsonb NOT NULL DEFAULT '{}'::jsonb
  CHECK (jsonb_typeof(labels) = 'object' AND octet_length(labels::text) <= 4096);

-- One row per mutation: who (tenant and actor), what (action), which public
-- resource, and how it ended. Never command text, file contents or secrets.
CREATE TABLE IF NOT EXISTS cmux_vm.audit_log (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  -- user:<stack user id> or key:<api key id>
  actor       text        NOT NULL CHECK (char_length(actor) BETWEEN 1 AND 160),
  action      text        NOT NULL CHECK (action ~ '^[a-z][a-z.]{1,63}$'),
  cmux_id     text        NULL CHECK (cmux_id IS NULL OR cmux_id ~ '^(vm|snap)_[0-9a-hjkmnp-tv-z]{26}$'),
  -- "ok" or the public error tag the caller received
  outcome     text        NOT NULL CHECK (outcome ~ '^[A-Za-z]{1,64}$'),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_tenant_created_idx
  ON cmux_vm.audit_log (tenant_id, created_at DESC);
