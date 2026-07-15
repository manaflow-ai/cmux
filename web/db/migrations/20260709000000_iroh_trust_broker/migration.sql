CREATE TABLE "iroh_account_security_states" (
  "user_id" text PRIMARY KEY NOT NULL,
  "lan_discovery_generation" integer DEFAULT 1 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "iroh_account_security_states_generation_check"
    CHECK ("lan_discovery_generation" >= 1)
);
--> statement-breakpoint
CREATE TABLE "iroh_endpoint_bindings" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "device_uuid" uuid NOT NULL,
  "app_instance_id" uuid NOT NULL,
  "tag" text NOT NULL,
  "platform" text NOT NULL,
  "display_name" text,
  "endpoint_id" text NOT NULL,
  "identity_generation" integer NOT NULL,
  "pairing_enabled" boolean DEFAULT false NOT NULL,
  "capabilities" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "path_hints" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "device_limit_override_used" boolean DEFAULT false NOT NULL,
  "last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
  "registered_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "revoked_at" timestamp with time zone,
  "revoked_reason" text,
  CONSTRAINT "iroh_endpoint_bindings_endpoint_id_check"
    CHECK ("endpoint_id" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "iroh_endpoint_bindings_identity_generation_check"
    CHECK ("identity_generation" >= 1),
  CONSTRAINT "iroh_endpoint_bindings_tag_check"
    CHECK ("tag" ~ '^[A-Za-z0-9._-]{1,64}$'),
  CONSTRAINT "iroh_endpoint_bindings_platform_check"
    CHECK ("platform" in ('mac', 'ios')),
  CONSTRAINT "iroh_endpoint_bindings_display_name_check"
    CHECK ("display_name" is null or "display_name" !~ '[[:cntrl:]]'),
  CONSTRAINT "iroh_endpoint_bindings_capabilities_check"
    CHECK (jsonb_typeof("capabilities") = 'array' and jsonb_array_length("capabilities") <= 32),
  CONSTRAINT "iroh_endpoint_bindings_path_hints_check"
    CHECK (jsonb_typeof("path_hints") = 'array' and jsonb_array_length("path_hints") <= 16)
);
--> statement-breakpoint
CREATE TABLE "iroh_registration_challenges" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "device_uuid" uuid NOT NULL,
  "app_instance_id" uuid NOT NULL,
  "tag" text NOT NULL,
  "endpoint_id" text NOT NULL,
  "identity_generation" integer NOT NULL,
  "payload_sha256" text NOT NULL,
  "nonce_hash" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  CONSTRAINT "iroh_registration_challenges_endpoint_id_check"
    CHECK ("endpoint_id" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "iroh_registration_challenges_identity_generation_check"
    CHECK ("identity_generation" >= 1),
  CONSTRAINT "iroh_registration_challenges_tag_check"
    CHECK ("tag" ~ '^[A-Za-z0-9._-]{1,64}$'),
  CONSTRAINT "iroh_registration_challenges_payload_hash_check"
    CHECK ("payload_sha256" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "iroh_registration_challenges_nonce_hash_check"
    CHECK ("nonce_hash" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE TABLE "iroh_pair_grant_issuances" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "jti" uuid NOT NULL,
  "initiator_binding_id" uuid NOT NULL,
  "acceptor_binding_id" uuid NOT NULL,
  "signing_key_id" text NOT NULL,
  "alpn" text DEFAULT 'cmux/mobile/1' NOT NULL,
  "scope" text DEFAULT 'cmux.mobile.attach' NOT NULL,
  "issued_at" timestamp with time zone NOT NULL,
  "not_before" timestamp with time zone NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "iroh_relay_token_issuances" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "binding_id" uuid NOT NULL,
  "endpoint_id_hash" text NOT NULL,
  "status" text DEFAULT 'pending' NOT NULL,
  "token_hash" text,
  "failure_code" text,
  "requested_at" timestamp with time zone NOT NULL,
  "completed_at" timestamp with time zone,
  "expires_at" timestamp with time zone,
  CONSTRAINT "iroh_relay_token_issuances_endpoint_hash_check"
    CHECK ("endpoint_id_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "iroh_relay_token_issuances_status_check"
    CHECK ("status" in ('pending', 'succeeded', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "iroh_pair_grant_issuances"
  ADD CONSTRAINT "iroh_pair_grant_issuances_initiator_binding_id_iroh_endpoint_bindings_id_fk"
  FOREIGN KEY ("initiator_binding_id") REFERENCES "public"."iroh_endpoint_bindings"("id")
  ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "iroh_pair_grant_issuances"
  ADD CONSTRAINT "iroh_pair_grant_issuances_acceptor_binding_id_iroh_endpoint_bindings_id_fk"
  FOREIGN KEY ("acceptor_binding_id") REFERENCES "public"."iroh_endpoint_bindings"("id")
  ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "iroh_relay_token_issuances"
  ADD CONSTRAINT "iroh_relay_token_issuances_binding_id_iroh_endpoint_bindings_id_fk"
  FOREIGN KEY ("binding_id") REFERENCES "public"."iroh_endpoint_bindings"("id")
  ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_endpoint_bindings_active_endpoint_unique"
  ON "iroh_endpoint_bindings" USING btree ("endpoint_id") WHERE "revoked_at" is null;
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_endpoint_bindings_active_app_instance_unique"
  ON "iroh_endpoint_bindings" USING btree ("app_instance_id") WHERE "revoked_at" is null;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_user_active_idx"
  ON "iroh_endpoint_bindings" USING btree ("user_id", "updated_at") WHERE "revoked_at" is null;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_user_device_active_idx"
  ON "iroh_endpoint_bindings" USING btree ("user_id", "device_uuid") WHERE "revoked_at" is null;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_revoked_idx"
  ON "iroh_endpoint_bindings" USING btree ("revoked_at") WHERE "revoked_at" is not null;
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_registration_challenges_nonce_hash_unique"
  ON "iroh_registration_challenges" USING btree ("nonce_hash");
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_user_created_idx"
  ON "iroh_registration_challenges" USING btree ("user_id", "created_at");
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_user_device_created_idx"
  ON "iroh_registration_challenges" USING btree ("user_id", "device_uuid", "created_at");
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_expires_idx"
  ON "iroh_registration_challenges" USING btree ("expires_at") WHERE "consumed_at" is null;
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_pair_grant_issuances_jti_unique"
  ON "iroh_pair_grant_issuances" USING btree ("jti");
--> statement-breakpoint
CREATE INDEX "iroh_pair_grant_issuances_user_issued_idx"
  ON "iroh_pair_grant_issuances" USING btree ("user_id", "issued_at");
--> statement-breakpoint
CREATE INDEX "iroh_pair_grant_issuances_acceptor_expires_idx"
  ON "iroh_pair_grant_issuances" USING btree ("acceptor_binding_id", "expires_at");
--> statement-breakpoint
CREATE INDEX "iroh_relay_token_issuances_binding_requested_idx"
  ON "iroh_relay_token_issuances" USING btree ("binding_id", "requested_at");
--> statement-breakpoint
CREATE INDEX "iroh_relay_token_issuances_user_requested_idx"
  ON "iroh_relay_token_issuances" USING btree ("user_id", "requested_at");
