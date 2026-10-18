-- cmux-next mobile backend schema. Vitess compatible: no foreign keys.
-- Timestamps are BIGINT ms since epoch. Secrets are stored as SHA-256/HMAC hex.

CREATE TABLE IF NOT EXISTS users (
  id VARCHAR(40) NOT NULL,
  email VARCHAR(320) NULL,
  name VARCHAR(200) NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY users_email (email)
);

CREATE TABLE IF NOT EXISTS identities (
  provider VARCHAR(16) NOT NULL,
  subject VARCHAR(255) NOT NULL,
  user_id VARCHAR(40) NOT NULL,
  email VARCHAR(320) NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (provider, subject),
  KEY identities_user (user_id)
);

CREATE TABLE IF NOT EXISTS email_codes (
  nonce VARCHAR(64) NOT NULL,
  email VARCHAR(320) NOT NULL,
  code_hash CHAR(64) NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  expires_at BIGINT NOT NULL,
  consumed_at BIGINT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (nonce),
  KEY email_codes_email_created (email, created_at)
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
  hash CHAR(64) NOT NULL,
  user_id VARCHAR(40) NOT NULL,
  family_id VARCHAR(40) NOT NULL,
  expires_at BIGINT NOT NULL,
  revoked_at BIGINT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (hash),
  KEY refresh_tokens_user (user_id),
  KEY refresh_tokens_family (family_id)
);

CREATE TABLE IF NOT EXISTS hosts (
  id VARCHAR(40) NOT NULL,
  user_id VARCHAR(40) NOT NULL,
  name VARCHAR(200) NOT NULL,
  os VARCHAR(64) NOT NULL,
  token_hash CHAR(64) NULL,
  last_seen_at BIGINT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY hosts_token_hash (token_hash),
  KEY hosts_user (user_id)
);

CREATE TABLE IF NOT EXISTS host_pairings (
  id VARCHAR(40) NOT NULL,
  device_code_hash CHAR(64) NOT NULL,
  user_code VARCHAR(16) NOT NULL,
  name VARCHAR(200) NOT NULL,
  os VARCHAR(64) NOT NULL,
  user_id VARCHAR(40) NULL,
  host_id VARCHAR(40) NULL,
  expires_at BIGINT NOT NULL,
  approved_at BIGINT NULL,
  claimed_at BIGINT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY host_pairings_device_code (device_code_hash),
  KEY host_pairings_user_code (user_code),
  KEY host_pairings_user (user_id)
);

CREATE TABLE IF NOT EXISTS oauth_codes (
  code_hash CHAR(64) NOT NULL,
  user_id VARCHAR(40) NOT NULL,
  code_challenge VARCHAR(128) NULL,
  expires_at BIGINT NOT NULL,
  consumed_at BIGINT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (code_hash),
  KEY oauth_codes_user (user_id)
);
