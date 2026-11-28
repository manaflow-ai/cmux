-- CMUX-owned DNS zones, persistent exact-host VM publications, and the browser
-- authorization state used by Freestyle TLS forwardAuth.
--
-- Freestyle owns certificate termination and the public TLS rule. Postgres is
-- authoritative for who owns a verified zone and exact hostname, the desired personal/team/public
-- policy, provider reconciliation state, and every one-use browser artifact.

CREATE TABLE "cloud_vm_publication_vm_guards" (
  "vm_id" uuid PRIMARY KEY NOT NULL,
  "teardown_started_at" timestamp with time zone,
  "operation_lease_id" uuid,
  "operation_lease_expires_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_pub_vm_guard_vm_fk"
    FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id") ON DELETE CASCADE,
  CONSTRAINT "cloud_vm_pub_vm_guard_lease_check"
    CHECK (("operation_lease_id" IS NULL) = ("operation_lease_expires_at" IS NULL))
);

CREATE TABLE "cloud_vm_domains" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "owner_user_id" text NOT NULL,
  "hostname" text NOT NULL,
  "kind" text NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "provider_verification_id" text,
  "verification_state" text NOT NULL,
  "certificate_state" text NOT NULL,
  "verification_records" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_domains_hostname_check"
    CHECK (char_length("hostname") BETWEEN 1 AND 253
      AND "hostname" = lower("hostname")
      AND right("hostname", 1) <> '.'
      AND "hostname" !~ '[[:space:][:cntrl:]/:]'),
  CONSTRAINT "cloud_vm_domains_kind_check"
    CHECK ("kind" IN ('generated', 'custom')),
  CONSTRAINT "cloud_vm_domains_verification_state_check"
    CHECK ("verification_state" IN ('not_required', 'pending', 'verified', 'failed')),
  CONSTRAINT "cloud_vm_domains_certificate_state_check"
    CHECK ("certificate_state" IN ('missing', 'pending', 'active', 'failed')),
  CONSTRAINT "cloud_vm_domains_generated_verification_check"
    CHECK ("kind" <> 'generated'
      OR ("verification_state" = 'not_required' AND "provider_verification_id" IS NULL)),
  CONSTRAINT "cloud_vm_domains_verified_provider_check"
    CHECK ("kind" <> 'custom' OR "verification_state" <> 'verified'
      OR "provider_verification_id" IS NOT NULL),
  CONSTRAINT "cloud_vm_domains_certificate_verification_check"
    CHECK ("certificate_state" <> 'active'
      OR "verification_state" IN ('not_required', 'verified')),
  CONSTRAINT "cloud_vm_domains_records_check"
    CHECK (jsonb_typeof("verification_records") = 'array'
      AND jsonb_array_length("verification_records") <= 16)
);

CREATE UNIQUE INDEX "cloud_vm_domains_owner_pending_hostname_unique"
  ON "cloud_vm_domains" ("owner_user_id", "hostname")
  WHERE "kind" = 'custom' AND "verification_state" = 'pending';
CREATE UNIQUE INDEX "cloud_vm_domains_claimed_hostname_unique"
  ON "cloud_vm_domains" ("hostname")
  WHERE "kind" = 'generated'
    OR ("kind" = 'custom' AND "verification_state" = 'verified');
CREATE UNIQUE INDEX "cloud_vm_domains_provider_verification_unique"
  ON "cloud_vm_domains" ("provider", "provider_verification_id")
  WHERE "provider_verification_id" IS NOT NULL;
CREATE INDEX "cloud_vm_domains_owner_created_idx"
  ON "cloud_vm_domains" ("owner_user_id", "created_at");

-- One provider-account forwardAuth config. The expiring lease makes bootstrap
-- concurrency-safe without holding a database transaction across provider I/O.
CREATE TABLE "cloud_vm_publication_provider_configs" (
  "provider" "vm_provider" PRIMARY KEY NOT NULL,
  "provider_forward_auth_id" text,
  "provisioning_lease_id" uuid,
  "provisioning_lease_expires_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_pub_provider_config_lease_check"
    CHECK (("provisioning_lease_id" IS NULL) = ("provisioning_lease_expires_at" IS NULL)),
  CONSTRAINT "cloud_vm_pub_provider_config_ready_check"
    CHECK ("provider_forward_auth_id" IS NULL OR "provisioning_lease_id" IS NULL)
);

CREATE TABLE "cloud_vm_publications" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "owner_user_id" text NOT NULL,
  "vm_id" uuid NOT NULL,
  "domain_id" uuid NOT NULL,
  "hostname" text NOT NULL,
  "hostname_claimed_at" timestamp with time zone,
  "port" integer NOT NULL,
  "access_mode" text NOT NULL,
  "team_id" text,
  "provider_tls_rule_id" text,
  "provider_forward_auth_id" text,
  "routing_revision" bigint DEFAULT 1 NOT NULL,
  "state" text DEFAULT 'provisioning' NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "disabled_at" timestamp with time zone,
  CONSTRAINT "cloud_vm_publications_vm_fk"
    FOREIGN KEY ("vm_id") REFERENCES "cloud_vms"("id") ON DELETE RESTRICT,
  CONSTRAINT "cloud_vm_publications_domain_fk"
    FOREIGN KEY ("domain_id") REFERENCES "cloud_vm_domains"("id") ON DELETE RESTRICT,
  CONSTRAINT "cloud_vm_publications_hostname_check"
    CHECK (char_length("hostname") BETWEEN 1 AND 253
      AND "hostname" = lower("hostname")
      AND right("hostname", 1) <> '.'
      AND "hostname" !~ '[[:space:][:cntrl:]/:]'),
  CONSTRAINT "cloud_vm_publications_port_check"
    CHECK ("port" BETWEEN 1 AND 65535),
  CONSTRAINT "cloud_vm_publications_access_mode_check"
    CHECK ("access_mode" IN ('personal', 'team', 'public')),
  CONSTRAINT "cloud_vm_publications_team_check"
    CHECK (("access_mode" = 'team') = ("team_id" IS NOT NULL)),
  CONSTRAINT "cloud_vm_publications_revision_check"
    CHECK ("routing_revision" > 0),
  CONSTRAINT "cloud_vm_publications_state_check"
    CHECK ("state" IN ('provisioning', 'active', 'unavailable', 'disabling', 'disabled')),
  CONSTRAINT "cloud_vm_publications_active_rule_check"
    CHECK ("state" <> 'active'
      OR ("provider_tls_rule_id" IS NOT NULL
        AND "hostname_claimed_at" IS NOT NULL)),
  CONSTRAINT "cloud_vm_publications_disabled_check"
    CHECK (("state" = 'disabled') = ("disabled_at" IS NOT NULL))
);

CREATE UNIQUE INDEX "cloud_vm_publications_owner_hostname_unique"
  ON "cloud_vm_publications" ("owner_user_id", "hostname")
  WHERE "disabled_at" IS NULL;
CREATE UNIQUE INDEX "cloud_vm_publications_claimed_hostname_unique"
  ON "cloud_vm_publications" ("hostname")
  WHERE "hostname_claimed_at" IS NOT NULL AND "disabled_at" IS NULL;
CREATE UNIQUE INDEX "cloud_vm_publications_provider_rule_unique"
  ON "cloud_vm_publications" ("provider_tls_rule_id")
  WHERE "provider_tls_rule_id" IS NOT NULL;
CREATE INDEX "cloud_vm_publications_owner_created_idx"
  ON "cloud_vm_publications" ("owner_user_id", "created_at");
CREATE INDEX "cloud_vm_publications_vm_state_idx"
  ON "cloud_vm_publications" ("vm_id", "state");
CREATE INDEX "cloud_vm_publications_state_updated_idx"
  ON "cloud_vm_publications" ("state", "updated_at");

CREATE TABLE "cloud_vm_publication_auth_transactions" (
  "transaction_hash" text PRIMARY KEY NOT NULL,
  "publication_id" uuid NOT NULL,
  "routing_revision" bigint NOT NULL,
  "pkce_challenge" text NOT NULL,
  "state_hash" text NOT NULL,
  "hostname" text NOT NULL,
  "return_path" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_pub_auth_tx_publication_fk"
    FOREIGN KEY ("publication_id") REFERENCES "cloud_vm_publications"("id") ON DELETE CASCADE,
  CONSTRAINT "cloud_vm_pub_auth_tx_hash_check"
    CHECK ("transaction_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "cloud_vm_pub_auth_tx_state_hash_check"
    CHECK ("state_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "cloud_vm_pub_auth_tx_pkce_check"
    CHECK ("pkce_challenge" ~ '^[A-Za-z0-9_-]{43}$'),
  CONSTRAINT "cloud_vm_pub_auth_tx_revision_check"
    CHECK ("routing_revision" > 0),
  CONSTRAINT "cloud_vm_pub_auth_tx_hostname_check"
    CHECK (char_length("hostname") BETWEEN 1 AND 253
      AND "hostname" = lower("hostname")
      AND right("hostname", 1) <> '.'
      AND "hostname" !~ '[[:space:][:cntrl:]/:]'),
  CONSTRAINT "cloud_vm_pub_auth_tx_return_path_check"
    CHECK (left("return_path", 1) = '/'
      AND left("return_path", 2) <> '//'
      AND "return_path" !~ '[[:cntrl:]]'),
  CONSTRAINT "cloud_vm_pub_auth_tx_expiry_check"
    CHECK ("expires_at" > "created_at")
);

CREATE INDEX "cloud_vm_pub_auth_tx_publication_idx"
  ON "cloud_vm_publication_auth_transactions" ("publication_id", "created_at");
CREATE INDEX "cloud_vm_pub_auth_tx_expiry_idx"
  ON "cloud_vm_publication_auth_transactions" ("expires_at");

CREATE TABLE "cloud_vm_publication_auth_codes" (
  "code_hash" text PRIMARY KEY NOT NULL,
  "transaction_hash" text NOT NULL,
  "publication_id" uuid NOT NULL,
  "user_id" text NOT NULL,
  "routing_revision" bigint NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_pub_auth_codes_transaction_fk"
    FOREIGN KEY ("transaction_hash") REFERENCES "cloud_vm_publication_auth_transactions"("transaction_hash") ON DELETE CASCADE,
  CONSTRAINT "cloud_vm_pub_auth_codes_publication_fk"
    FOREIGN KEY ("publication_id") REFERENCES "cloud_vm_publications"("id") ON DELETE CASCADE,
  CONSTRAINT "cloud_vm_pub_auth_codes_hash_check"
    CHECK ("code_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "cloud_vm_pub_auth_codes_revision_check"
    CHECK ("routing_revision" > 0),
  CONSTRAINT "cloud_vm_pub_auth_codes_expiry_check"
    CHECK ("expires_at" > "created_at")
);

CREATE UNIQUE INDEX "cloud_vm_pub_auth_codes_transaction_unique"
  ON "cloud_vm_publication_auth_codes" ("transaction_hash");
CREATE INDEX "cloud_vm_pub_auth_codes_publication_idx"
  ON "cloud_vm_publication_auth_codes" ("publication_id", "created_at");
CREATE INDEX "cloud_vm_pub_auth_codes_expiry_idx"
  ON "cloud_vm_publication_auth_codes" ("expires_at");

CREATE TABLE "cloud_vm_publication_sessions" (
  "token_hash" text PRIMARY KEY NOT NULL,
  "publication_id" uuid NOT NULL,
  "user_id" text NOT NULL,
  "routing_revision" bigint NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "revoked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_pub_sessions_publication_fk"
    FOREIGN KEY ("publication_id") REFERENCES "cloud_vm_publications"("id") ON DELETE CASCADE,
  CONSTRAINT "cloud_vm_pub_sessions_hash_check"
    CHECK ("token_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "cloud_vm_pub_sessions_revision_check"
    CHECK ("routing_revision" > 0),
  CONSTRAINT "cloud_vm_pub_sessions_expiry_check"
    CHECK ("expires_at" > "created_at")
);

CREATE INDEX "cloud_vm_pub_sessions_publication_idx"
  ON "cloud_vm_publication_sessions" ("publication_id", "expires_at");
CREATE INDEX "cloud_vm_pub_sessions_user_idx"
  ON "cloud_vm_publication_sessions" ("user_id", "expires_at");
CREATE INDEX "cloud_vm_pub_sessions_expiry_idx"
  ON "cloud_vm_publication_sessions" ("expires_at");
