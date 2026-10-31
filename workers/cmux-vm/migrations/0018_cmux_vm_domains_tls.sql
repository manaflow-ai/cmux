-- Domains, domain verifications, TLS rules and forward-auth checks (cx-b4h.6). Additive only.
--
-- The provider holds verifications, certificates, TLS rules and forward-auth
-- configurations account-wide; these tables make each one belong to exactly one
-- tenant. A row of another tenant is indistinguishable from no row.
--
-- domains is also the reservation: one row per domain name across all tenants
-- (the unique index), pending (verified_at NULL) while its tenant's challenge is
-- outstanding and verified afterwards. A pending reservation older than seven
-- days may be taken over by another tenant; a verified one only by being
-- released. Provider ids (verification, rule and forward-auth ids) are
-- server-side only and never returned. Secret header values are never stored:
-- only their names.
--
-- Apply through the versioned migration runner before deploying code; grant the
-- Worker SELECT, INSERT, UPDATE and DELETE on the four new tables through the
-- existing operator role workflow. Roll back code first; retain the rows.
CREATE TABLE cmux_vm.domains (
  id          text        PRIMARY KEY CHECK (id ~ '^dom_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id   text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  domain      text        NOT NULL UNIQUE CHECK (char_length(domain) BETWEEN 3 AND 253 AND domain ~ '^[a-z0-9.-]+$'),
  created_by  text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at  timestamptz NOT NULL,
  verified_at timestamptz NULL
);
CREATE INDEX domains_tenant_idx ON cmux_vm.domains (tenant_id, verified_at);

CREATE TABLE cmux_vm.domain_verifications (
  id                       text        PRIMARY KEY CHECK (id ~ '^dvr_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id                text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  domain                   text        NOT NULL CHECK (char_length(domain) BETWEEN 3 AND 253),
  upstream_verification_id text        NOT NULL UNIQUE CHECK (char_length(upstream_verification_id) BETWEEN 1 AND 256),
  record_name              text        NOT NULL CHECK (char_length(record_name) BETWEEN 1 AND 300),
  verification_code        text        NOT NULL CHECK (char_length(verification_code) BETWEEN 1 AND 512),
  created_by               text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at               timestamptz NOT NULL,
  verified_at              timestamptz NULL
);
CREATE INDEX domain_verifications_tenant_idx ON cmux_vm.domain_verifications (tenant_id, domain);

CREATE TABLE cmux_vm.tls_forward_auths (
  id                    text        PRIMARY KEY CHECK (id ~ '^fwa_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id             text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  upstream_id           text        NOT NULL UNIQUE CHECK (char_length(upstream_id) BETWEEN 1 AND 256),
  url                   text        NOT NULL CHECK (char_length(url) BETWEEN 9 AND 2048),
  timeout_ms            integer     NOT NULL CHECK (timeout_ms BETWEEN 100 AND 5000),
  header_names          jsonb       NOT NULL CHECK (jsonb_typeof(header_names) = 'array'),
  auth_response_headers jsonb       NOT NULL CHECK (jsonb_typeof(auth_response_headers) = 'array'),
  protected_cookies     jsonb       NOT NULL CHECK (jsonb_typeof(protected_cookies) = 'array'),
  created_by            text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at            timestamptz NOT NULL,
  updated_at            timestamptz NOT NULL
);
CREATE INDEX tls_forward_auths_tenant_idx ON cmux_vm.tls_forward_auths (tenant_id, created_at);

CREATE TABLE cmux_vm.tls_rules (
  id              text        PRIMARY KEY CHECK (id ~ '^tlsr_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id       text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  upstream_id     text        NOT NULL UNIQUE CHECK (char_length(upstream_id) BETWEEN 1 AND 256),
  domain          text        NOT NULL CHECK (char_length(domain) BETWEEN 3 AND 255),
  -- The public rule (TlsRuleSpec): VM and forward-auth ids are cmux ids; header names only.
  spec            jsonb       NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
  vm_ids          jsonb       NOT NULL CHECK (jsonb_typeof(vm_ids) = 'array'),
  forward_auth_id text        NULL,
  created_by      text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at      timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL
);
CREATE INDEX tls_rules_tenant_idx ON cmux_vm.tls_rules (tenant_id, created_at);
