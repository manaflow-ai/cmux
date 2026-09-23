CREATE TABLE `account_bindings` (
	`binding_id` text PRIMARY KEY,
	`endpoint_id` text NOT NULL,
	`device_id` text NOT NULL,
	`client_namespace` text NOT NULL,
	`platform` text NOT NULL,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`last_seen_at` integer NOT NULL,
	`registered_at` integer NOT NULL,
	`revoked_at` integer,
	`tombstone_expires_at` integer,
	CONSTRAINT "account_bindings_endpoint_check" CHECK(length("endpoint_id") = 64),
	CONSTRAINT "account_bindings_platform_check" CHECK("platform" in ('mac', 'ios')),
	CONSTRAINT "account_bindings_payload_size_check" CHECK("payload_bytes" between 0 and 65536),
	CONSTRAINT "account_bindings_revocation_check" CHECK((
      ("revoked_at" is null and "tombstone_expires_at" is null) or
      ("revoked_at" is not null and "tombstone_expires_at" is not null and
       "tombstone_expires_at" >= "revoked_at" + 2592000000)
    ))
);
--> statement-breakpoint
CREATE TABLE `account_challenges` (
	`challenge_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_challenges_payload_size_check" CHECK("payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
CREATE TABLE `account_meta` (
	`key` text PRIMARY KEY,
	`value` text NOT NULL,
	CONSTRAINT "account_meta_key_check" CHECK("key" in ('route_revision', 'lan_generation', 'revocation_epoch')),
	CONSTRAINT "account_meta_value_check" CHECK(length("value") <= 128)
);
--> statement-breakpoint
CREATE TABLE `account_pair_grants` (
	`grant_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_pair_grants_payload_size_check" CHECK("payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
CREATE TABLE `account_preferences` (
	`preference_key` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT "account_preferences_key_check" CHECK("preference_key" = 'relay'),
	CONSTRAINT "account_preferences_payload_size_check" CHECK("payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
CREATE TABLE `account_relay_issuances` (
	`issuance_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_relay_issuances_payload_size_check" CHECK("payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
CREATE TABLE `account_storage_usage` (
	`id` integer PRIMARY KEY,
	`payload_bytes` integer NOT NULL,
	`records` integer NOT NULL,
	`live_bindings` integer NOT NULL,
	CONSTRAINT "account_storage_usage_id_check" CHECK("id" = 1),
	CONSTRAINT "account_storage_usage_payload_check" CHECK("payload_bytes" between 0 and 8388608),
	CONSTRAINT "account_storage_usage_records_check" CHECK("records" between 0 and 4096),
	CONSTRAINT "account_storage_usage_bindings_check" CHECK("live_bindings" between 0 and 32)
);
--> statement-breakpoint
CREATE TABLE `drizzle_transaction_probe` (
	`id` integer PRIMARY KEY,
	`value` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `account_bindings_endpoint_live` ON `account_bindings` (`endpoint_id`) WHERE "account_bindings"."revoked_at" is null;--> statement-breakpoint
CREATE INDEX `account_bindings_live_expiry` ON `account_bindings` (`last_seen_at`) WHERE "account_bindings"."revoked_at" is null;--> statement-breakpoint
CREATE INDEX `account_bindings_revoked_expiry` ON `account_bindings` (`tombstone_expires_at`) WHERE "account_bindings"."revoked_at" is not null;--> statement-breakpoint
CREATE INDEX `account_challenges_expiry` ON `account_challenges` (`expires_at`);--> statement-breakpoint
CREATE INDEX `account_pair_grants_expiry` ON `account_pair_grants` (`expires_at`);--> statement-breakpoint
CREATE INDEX `account_relay_issuances_expiry` ON `account_relay_issuances` (`expires_at`);
--> statement-breakpoint
INSERT INTO `account_storage_usage` (`id`, `payload_bytes`, `records`, `live_bindings`) VALUES (1, 0, 0, 0);
