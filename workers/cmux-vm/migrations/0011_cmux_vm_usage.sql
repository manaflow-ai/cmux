-- contract: add provider metadata and metering tables for tenant billing
-- cmux VM metered usage (cx-b4h.20). Additive only; the operator applies this
-- file after 0010 on staging first. The Worker never runs DDL.
--
-- Grants: the operator grants the Worker role SELECT, INSERT and UPDATE on
-- usage_intervals, SELECT on billing_accounts, and SELECT and INSERT/UPDATE on
-- usage_exports and usage_adjustments. The release role contract owns the
-- actual per-branch role grants.
--
-- Rollback: first disable the Worker build that reads these tables. Preserve
-- billing receipts, then in one transaction drop the usage indexes and tables,
-- and drop resources.provider and resources.region. Never delete exported
-- Stripe events as a rollback operation.

ALTER TABLE cmux_vm.resources
  ADD COLUMN provider text NULL
    CHECK (provider IS NULL OR char_length(provider) BETWEEN 1 AND 64),
  ADD COLUMN region text NULL
    CHECK (region IS NULL OR char_length(region) BETWEEN 1 AND 128);

CREATE TABLE cmux_vm.usage_intervals (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
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

CREATE UNIQUE INDEX usage_intervals_open_key
  ON cmux_vm.usage_intervals (tenant_id, upstream_vm_id)
  WHERE ended_at IS NULL;

CREATE INDEX usage_intervals_tenant_time_idx
  ON cmux_vm.usage_intervals (tenant_id, started_at, ended_at);

CREATE INDEX usage_intervals_started_idx
  ON cmux_vm.usage_intervals (started_at);

CREATE TABLE cmux_vm.billing_accounts (
  tenant_id          text        PRIMARY KEY CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  stripe_customer_id text        NOT NULL CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 256),
  status             text        NOT NULL CHECK (status IN ('active', 'inactive', 'suspended')),
  activated_at       timestamptz NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX billing_accounts_status_idx
  ON cmux_vm.billing_accounts (status, activated_at, tenant_id);

CREATE TABLE cmux_vm.usage_exports (
  tenant_id          text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  hour_start         timestamptz NOT NULL,
  stripe_customer_id text        NOT NULL CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 256),
  identifier         text        NOT NULL CHECK (char_length(identifier) BETWEEN 1 AND 100),
  value_microdollars bigint      NOT NULL,
  status             text        NOT NULL CHECK (status IN ('pending', 'exported', 'failed')),
  attempts           integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error         text        NULL,
  exported_at        timestamptz NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, hour_start),
  UNIQUE (identifier)
);

CREATE INDEX usage_exports_hour_status_idx
  ON cmux_vm.usage_exports (hour_start, status);

CREATE TABLE cmux_vm.usage_adjustments (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  hour_start         timestamptz NOT NULL,
  stripe_customer_id text        NOT NULL CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 256),
  identifier         text        NOT NULL CHECK (char_length(identifier) BETWEEN 1 AND 100),
  value_microdollars bigint      NOT NULL,
  status             text        NOT NULL CHECK (status IN ('pending', 'exported', 'failed')),
  attempts           integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error         text        NULL,
  exported_at        timestamptz NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (identifier)
);

CREATE INDEX usage_adjustments_hour_status_idx
  ON cmux_vm.usage_adjustments (hour_start, status);
