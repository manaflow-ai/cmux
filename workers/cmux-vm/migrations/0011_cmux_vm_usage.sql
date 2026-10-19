-- cmux VM metered usage (cx-b4h.20). Additive only: interval facts are
-- append-only apart from closing an open interval, and every close names its
-- source. Money is integer micro-dollars. Applied by an operator, staging first.

CREATE TABLE IF NOT EXISTS cmux_vm.usage_intervals (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id         text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  provider          text        NOT NULL CHECK (char_length(provider) BETWEEN 1 AND 64),
  region            text        NOT NULL CHECK (char_length(region) BETWEEN 1 AND 128),
  upstream_vm_id    text        NOT NULL CHECK (char_length(upstream_vm_id) BETWEEN 1 AND 256),
  cmux_vm_id        text        NULL CHECK (cmux_vm_id IS NULL OR cmux_vm_id ~ '^vm_[0-9a-hjkmnp-tv-z]{26}$'),
  started_at        timestamptz NOT NULL,
  ended_at          timestamptz NULL,
  vcpus             integer     NOT NULL CHECK (vcpus >= 0),
  memory_mb         integer     NOT NULL CHECK (memory_mb >= 0),
  storage_mb        integer     NOT NULL CHECK (storage_mb >= 0),
  compute_billed    boolean     NOT NULL,
  source            text        NOT NULL CHECK (source IN ('api', 'reconcile', 'identity')),
  ended_source      text        NULL CHECK (ended_source IS NULL OR ended_source IN ('api', 'reconcile', 'identity')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at IS NULL OR ended_at >= started_at),
  CHECK ((ended_at IS NULL) = (ended_source IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS usage_intervals_open_key
  ON cmux_vm.usage_intervals (tenant_id, upstream_vm_id)
  WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS usage_intervals_tenant_time_idx
  ON cmux_vm.usage_intervals (tenant_id, started_at, ended_at);

CREATE INDEX IF NOT EXISTS usage_intervals_upstream_time_idx
  ON cmux_vm.usage_intervals (tenant_id, upstream_vm_id, started_at);

CREATE TABLE IF NOT EXISTS cmux_vm.billing_accounts (
  tenant_id         text        PRIMARY KEY CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  stripe_customer_id text       NOT NULL CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 256),
  status             text        NOT NULL CHECK (status IN ('active', 'inactive', 'suspended')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS billing_accounts_status_idx
  ON cmux_vm.billing_accounts (status, tenant_id);

CREATE TABLE IF NOT EXISTS cmux_vm.usage_exports (
  tenant_id          text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  hour_start         timestamptz NOT NULL,
  stripe_customer_id text        NOT NULL CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 256),
  identifier         text        NOT NULL CHECK (char_length(identifier) BETWEEN 1 AND 255),
  value_microdollars bigint      NOT NULL CHECK (value_microdollars >= 0),
  exported_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, hour_start),
  UNIQUE (identifier)
);
