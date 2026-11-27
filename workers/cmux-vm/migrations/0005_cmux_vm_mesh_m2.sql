-- cmux VM mesh experiment M2 (cx-0op.4): install keys, signed-request replay
-- protection, one-time enrollment codes, key rotation. Inside the cmux_vm
-- schema only and additive: two nullable columns on mesh_devices (rows from M1
-- keep NULL) and two new tables with their indexes. No CHECK is changed and
-- nothing is dropped. No grants (the operator grants the Worker role
-- separately). Applied by an operator (staging rehearsal first), never by the
-- Worker. Needs 0001-0004.

-- The device's install public key (ECDSA P-256, the 65-byte uncompressed point,
-- base64). Enroll and key rotation must be signed by it. NULL only for devices
-- enrolled before M2; such a device cannot rotate and must enroll again.
ALTER TABLE cmux_vm.mesh_devices
  ADD COLUMN IF NOT EXISTS install_public_key text NULL
    CHECK (install_public_key IS NULL OR install_public_key ~ '^B[A-Za-z0-9+/]{86}=$');

-- When the device's WireGuard key last changed through rotate-key.
ALTER TABLE cmux_vm.mesh_devices
  ADD COLUMN IF NOT EXISTS key_rotated_at timestamptz NULL;

-- Every accepted signed request, by the SHA-256 of its signed message (not of
-- the signature, which ECDSA lets anyone re-encode). A second request with the
-- same message is a replay. Rows past expires_at (signedAt + the accepted clock
-- skew) can no longer match a fresh request and are pruned by the Worker.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_signed_requests (
  message_sha256 text        PRIMARY KEY CHECK (message_sha256 ~ '^[0-9a-f]{64}$'),
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  purpose        text        NOT NULL CHECK (purpose IN ('enroll', 'rotate-key')),
  expires_at     timestamptz NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mesh_signed_requests_expiry_idx
  ON cmux_vm.mesh_signed_requests (expires_at);

-- One-time enrollment codes for headless machines. Only the SHA-256 of the code
-- is stored; the code itself is returned once, at creation. Single use
-- (used_at), valid at most 10 minutes. A device enrolled with a code belongs to
-- the code's creator.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_enrollment_codes (
  code_sha256    text        PRIMARY KEY CHECK (code_sha256 ~ '^[0-9a-f]{64}$'),
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  mesh_cmux_id   text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  created_by     text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at     timestamptz NOT NULL,
  expires_at     timestamptz NOT NULL,
  used_at        timestamptz NULL,
  device_cmux_id text        NULL CHECK (device_cmux_id IS NULL OR device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '10 minutes')
);

-- The per-mesh hourly code budget counts recent codes of one mesh.
CREATE INDEX IF NOT EXISTS mesh_enrollment_codes_mesh_idx
  ON cmux_vm.mesh_enrollment_codes (tenant_id, mesh_cmux_id, created_at);
