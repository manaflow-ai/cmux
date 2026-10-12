-- cmux-next-native PlanetScale (MySQL/Vitess) schema.
-- Ids are random 128-bit values rendered as 32 lowercase hex chars.
-- Secrets (host_secret, session tokens) are stored only as SHA-256 hex hashes.
-- Times are unix epoch milliseconds (BIGINT).

CREATE TABLE IF NOT EXISTS users (
  id CHAR(32) NOT NULL PRIMARY KEY,
  apple_sub VARCHAR(255) NULL,
  email VARCHAR(320) NULL,
  display_name VARCHAR(255) NULL,
  created_at BIGINT NOT NULL,
  UNIQUE KEY users_apple_sub (apple_sub),
  UNIQUE KEY users_email (email)
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash CHAR(64) NOT NULL PRIMARY KEY,
  user_id CHAR(32) NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  KEY sessions_user (user_id)
);

CREATE TABLE IF NOT EXISTS hosts (
  id CHAR(32) NOT NULL PRIMARY KEY,
  user_id CHAR(32) NULL,
  name VARCHAR(255) NOT NULL,
  platform VARCHAR(64) NOT NULL,
  secret_hash CHAR(64) NOT NULL,
  created_at BIGINT NOT NULL,
  paired_at BIGINT NULL,
  last_seen BIGINT NULL,
  online TINYINT NOT NULL DEFAULT 0,
  UNIQUE KEY hosts_secret_hash (secret_hash),
  KEY hosts_user (user_id)
);

CREATE TABLE IF NOT EXISTS pairing_codes (
  code CHAR(8) NOT NULL PRIMARY KEY,
  host_id CHAR(32) NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  used_at BIGINT NULL,
  KEY pairing_codes_host (host_id)
);

CREATE TABLE IF NOT EXISTS devices (
  id CHAR(32) NOT NULL PRIMARY KEY,
  user_id CHAR(32) NOT NULL,
  apns_token VARCHAR(255) NOT NULL,
  environment VARCHAR(16) NOT NULL DEFAULT 'production',
  bundle_id VARCHAR(255) NULL,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE KEY devices_apns_token (apns_token),
  KEY devices_user (user_id)
);
