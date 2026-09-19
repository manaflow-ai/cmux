PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_bindings` (
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
	CONSTRAINT "account_bindings_payload_size_check" CHECK("payload_bytes" = length(cast("payload" as blob)) and "payload_bytes" between 0 and 65536),
	CONSTRAINT "account_bindings_revocation_check" CHECK((
      ("revoked_at" is null and "tombstone_expires_at" is null) or
      ("revoked_at" is not null and "tombstone_expires_at" is not null and
       "tombstone_expires_at" >= "revoked_at" + 2592000000)
    ))
);
--> statement-breakpoint
INSERT INTO `__new_account_bindings`(`binding_id`, `endpoint_id`, `device_id`, `client_namespace`, `platform`, `payload`, `payload_bytes`, `last_seen_at`, `registered_at`, `revoked_at`, `tombstone_expires_at`) SELECT `binding_id`, `endpoint_id`, `device_id`, `client_namespace`, `platform`, `payload`, `payload_bytes`, `last_seen_at`, `registered_at`, `revoked_at`, `tombstone_expires_at` FROM `account_bindings`;--> statement-breakpoint
DROP TABLE `account_bindings`;--> statement-breakpoint
ALTER TABLE `__new_account_bindings` RENAME TO `account_bindings`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_challenges` (
	`challenge_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_challenges_payload_size_check" CHECK("payload_bytes" = length(cast("payload" as blob)) and "payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
INSERT INTO `__new_account_challenges`(`challenge_id`, `payload`, `payload_bytes`, `expires_at`) SELECT `challenge_id`, `payload`, `payload_bytes`, `expires_at` FROM `account_challenges`;--> statement-breakpoint
DROP TABLE `account_challenges`;--> statement-breakpoint
ALTER TABLE `__new_account_challenges` RENAME TO `account_challenges`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_pair_grants` (
	`grant_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_pair_grants_payload_size_check" CHECK("payload_bytes" = length(cast("payload" as blob)) and "payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
INSERT INTO `__new_account_pair_grants`(`grant_id`, `payload`, `payload_bytes`, `expires_at`) SELECT `grant_id`, `payload`, `payload_bytes`, `expires_at` FROM `account_pair_grants`;--> statement-breakpoint
DROP TABLE `account_pair_grants`;--> statement-breakpoint
ALTER TABLE `__new_account_pair_grants` RENAME TO `account_pair_grants`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_preferences` (
	`preference_key` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT "account_preferences_key_check" CHECK("preference_key" = 'relay'),
	CONSTRAINT "account_preferences_payload_size_check" CHECK("payload_bytes" = length(cast("payload" as blob)) and "payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
INSERT INTO `__new_account_preferences`(`preference_key`, `payload`, `payload_bytes`, `updated_at`) SELECT `preference_key`, `payload`, `payload_bytes`, `updated_at` FROM `account_preferences`;--> statement-breakpoint
DROP TABLE `account_preferences`;--> statement-breakpoint
ALTER TABLE `__new_account_preferences` RENAME TO `account_preferences`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_relay_issuances` (
	`issuance_id` text PRIMARY KEY,
	`payload` text NOT NULL,
	`payload_bytes` integer NOT NULL,
	`expires_at` integer NOT NULL,
	CONSTRAINT "account_relay_issuances_payload_size_check" CHECK("payload_bytes" = length(cast("payload" as blob)) and "payload_bytes" between 0 and 65536)
);
--> statement-breakpoint
INSERT INTO `__new_account_relay_issuances`(`issuance_id`, `payload`, `payload_bytes`, `expires_at`) SELECT `issuance_id`, `payload`, `payload_bytes`, `expires_at` FROM `account_relay_issuances`;--> statement-breakpoint
DROP TABLE `account_relay_issuances`;--> statement-breakpoint
ALTER TABLE `__new_account_relay_issuances` RENAME TO `account_relay_issuances`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE UNIQUE INDEX `account_bindings_endpoint_live` ON `account_bindings` (`endpoint_id`) WHERE "account_bindings"."revoked_at" is null;--> statement-breakpoint
CREATE INDEX `account_bindings_live_expiry` ON `account_bindings` (`last_seen_at`) WHERE "account_bindings"."revoked_at" is null;--> statement-breakpoint
CREATE INDEX `account_bindings_revoked_expiry` ON `account_bindings` (`tombstone_expires_at`) WHERE "account_bindings"."revoked_at" is not null;--> statement-breakpoint
CREATE INDEX `account_challenges_expiry` ON `account_challenges` (`expires_at`);--> statement-breakpoint
CREATE INDEX `account_pair_grants_expiry` ON `account_pair_grants` (`expires_at`);--> statement-breakpoint
CREATE INDEX `account_relay_issuances_expiry` ON `account_relay_issuances` (`expires_at`);--> statement-breakpoint
DROP TABLE `drizzle_transaction_probe`;