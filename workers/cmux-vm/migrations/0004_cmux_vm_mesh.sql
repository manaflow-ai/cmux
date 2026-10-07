-- cmux VM mesh experiment (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md). Inside
-- the cmux_vm schema only. Additive: the kind/prefix CHECKs on
-- cmux_vm.resources and the cmux_id CHECK on cmux_vm.audit_log are replaced
-- by wider ones that accept every value the old ones did, plus mesh_, dev_
-- and tun_; five new tables with their indexes. Nothing is dropped except the
-- three replaced CHECK constraints. No grants (the operator grants the Worker
-- role privileges on the new tables separately). Applied by an operator
-- (staging rehearsal first), never by the Worker. Needs 0001, 0002 and 0003.

-- New kinds: a mesh (upstream: its private network), a device (upstream: its
-- tunnel, which deleting the device deletes) and a tunnel.
ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_cmux_id_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_cmux_id_check
  CHECK (cmux_id ~ '^(vm|snap|mesh|dev|tun)_[0-9a-hjkmnp-tv-z]{26}$');

ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_kind_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_kind_check
  CHECK (kind IN ('vm', 'snapshot', 'mesh', 'device', 'tunnel'));

ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_check;
ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_kind_prefix_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_kind_prefix_check
  CHECK ((kind = 'vm' AND cmux_id LIKE 'vm\_%')
      OR (kind = 'snapshot' AND cmux_id LIKE 'snap\_%')
      OR (kind = 'mesh' AND cmux_id LIKE 'mesh\_%')
      OR (kind = 'device' AND cmux_id LIKE 'dev\_%')
      OR (kind = 'tunnel' AND cmux_id LIKE 'tun\_%'));

-- Audit rows name mesh resources by public id too.
ALTER TABLE cmux_vm.audit_log DROP CONSTRAINT IF EXISTS audit_log_cmux_id_check;
ALTER TABLE cmux_vm.audit_log ADD CONSTRAINT audit_log_cmux_id_check
  CHECK (cmux_id IS NULL OR cmux_id ~ '^(vm|snap|vmk|mesh|dev|tun)_[0-9a-hjkmnp-tv-z]{26}$');

-- Each mesh's IPv4 /20 out of 10.128.0.0/9 (slot 0..2047), unique across all tenants.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_cidrs (
  mesh_cmux_id text        PRIMARY KEY CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id    text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  slot         integer     NOT NULL UNIQUE CHECK (slot BETWEEN 0 AND 2047),
  cidr         text        NOT NULL CHECK (cidr ~ '^10\.[0-9]{1,3}\.[0-9]{1,3}\.0/20$'),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cmux_vm.mesh_devices (
  device_cmux_id text        PRIMARY KEY CHECK (device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  mesh_cmux_id   text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  tunnel_cmux_id text        NOT NULL UNIQUE CHECK (tunnel_cmux_id ~ '^tun_[0-9a-hjkmnp-tv-z]{26}$'),
  name           text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  -- The device's WireGuard public key (base64, 32 bytes). Private keys are never stored.
  wg_public_key  text        NOT NULL CHECK (wg_public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  created_by     text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz NULL
);

CREATE INDEX IF NOT EXISTS mesh_devices_mesh_idx
  ON cmux_vm.mesh_devices (tenant_id, mesh_cmux_id, created_at)
  WHERE deleted_at IS NULL;

-- One live key per mesh.
CREATE UNIQUE INDEX IF NOT EXISTS mesh_devices_mesh_key_live
  ON cmux_vm.mesh_devices (mesh_cmux_id, wg_public_key)
  WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS cmux_vm.mesh_members (
  mesh_cmux_id text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  vm_cmux_id   text        NOT NULL CHECK (vm_cmux_id ~ '^vm_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id    text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  ipv4         text        NULL CHECK (ipv4 IS NULL OR ipv4 ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'),
  attached_at  timestamptz NOT NULL DEFAULT now(),
  detached_at  timestamptz NULL
);

-- A VM is in at most one mesh at a time (the provider allows one network per VM).
CREATE UNIQUE INDEX IF NOT EXISTS mesh_members_vm_live
  ON cmux_vm.mesh_members (vm_cmux_id)
  WHERE detached_at IS NULL;

CREATE INDEX IF NOT EXISTS mesh_members_mesh_idx
  ON cmux_vm.mesh_members (tenant_id, mesh_cmux_id)
  WHERE detached_at IS NULL;

-- Immutable ACL versions; undo is applying an older document as a new version.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_acl_versions (
  mesh_cmux_id text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id    text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  version      integer     NOT NULL CHECK (version >= 1),
  document     jsonb       NOT NULL CHECK (jsonb_typeof(document) = 'object' AND octet_length(document::text) <= 262144),
  sha256       text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  author       text        NOT NULL CHECK (char_length(author) BETWEEN 1 AND 160),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mesh_cmux_id, version)
);

CREATE INDEX IF NOT EXISTS mesh_acl_versions_recent_idx
  ON cmux_vm.mesh_acl_versions (tenant_id, mesh_cmux_id, created_at DESC);

-- Provider firewall rules the ACL created. Internal: the provider id is never
-- returned to a client; the Worker deletes only rules listed here.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_firewall_rules (
  mesh_cmux_id     text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id        text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  rule_key         text        NOT NULL CHECK (char_length(rule_key) BETWEEN 1 AND 160),
  upstream_rule_id text        NOT NULL CHECK (char_length(upstream_rule_id) BETWEEN 1 AND 256),
  device_cmux_id   text        NOT NULL CHECK (device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  vm_cmux_id       text        NOT NULL CHECK (vm_cmux_id ~ '^vm_[0-9a-hjkmnp-tv-z]{26}$'),
  protocol         text        NULL CHECK (protocol IS NULL OR protocol IN ('tcp', 'udp', 'icmp')),
  port             integer     NULL CHECK (port IS NULL OR port BETWEEN 1 AND 65535),
  created_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS mesh_firewall_rules_key_live
  ON cmux_vm.mesh_firewall_rules (mesh_cmux_id, rule_key)
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS mesh_firewall_rules_upstream_key
  ON cmux_vm.mesh_firewall_rules (upstream_rule_id);
