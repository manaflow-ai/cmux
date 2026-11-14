-- cmux-next-mobile-native initial schema (PlanetScale MySQL, no foreign keys).
-- All timestamps are UTC DATETIME(3) written by the Worker.

CREATE TABLE IF NOT EXISTS users (
  id            CHAR(36)     NOT NULL,
  email         VARCHAR(320) NULL,
  display_name  VARCHAR(100) NULL,
  created_at    DATETIME(3)  NOT NULL,
  updated_at    DATETIME(3)  NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY users_email (email)
);

CREATE TABLE IF NOT EXISTS auth_identities (
  id          CHAR(36)     NOT NULL,
  user_id     CHAR(36)     NOT NULL,
  provider    VARCHAR(16)  NOT NULL, -- 'email' | 'apple'
  subject     VARCHAR(320) NOT NULL, -- lowercased email, or Apple `sub`
  email       VARCHAR(320) NULL,
  created_at  DATETIME(3)  NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY auth_identities_provider_subject (provider, subject),
  KEY auth_identities_user (user_id)
);

CREATE TABLE IF NOT EXISTS email_codes (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email        VARCHAR(320)    NOT NULL,
  code_hash    CHAR(64)        NOT NULL, -- sha256(email + ':' + code)
  ip           VARCHAR(64)     NULL,
  attempts     INT             NOT NULL DEFAULT 0,
  created_at   DATETIME(3)     NOT NULL,
  expires_at   DATETIME(3)     NOT NULL,
  consumed_at  DATETIME(3)     NULL,
  PRIMARY KEY (id),
  KEY email_codes_email_created (email, created_at),
  KEY email_codes_ip_created (ip, created_at)
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
  id           CHAR(36)    NOT NULL,
  user_id      CHAR(36)    NOT NULL,
  token_hash   CHAR(64)    NOT NULL,
  created_at   DATETIME(3) NOT NULL,
  expires_at   DATETIME(3) NOT NULL,
  revoked_at   DATETIME(3) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY refresh_tokens_hash (token_hash),
  KEY refresh_tokens_user (user_id)
);

CREATE TABLE IF NOT EXISTS hosts (
  id            CHAR(36)     NOT NULL,
  user_id       CHAR(36)     NOT NULL,
  name          VARCHAR(100) NOT NULL,
  platform      VARCHAR(64)  NOT NULL,
  app_version   VARCHAR(64)  NOT NULL,
  token_hash    CHAR(64)     NULL, -- NULL until the pairing poll delivers the token
  created_at    DATETIME(3)  NOT NULL,
  last_seen_at  DATETIME(3)  NULL,
  PRIMARY KEY (id),
  UNIQUE KEY hosts_token_hash (token_hash),
  KEY hosts_user (user_id)
);

CREATE TABLE IF NOT EXISTS pairings (
  id                CHAR(36)     NOT NULL,
  code              CHAR(6)      NOT NULL,
  poll_secret_hash  CHAR(64)     NOT NULL,
  host_name         VARCHAR(100) NOT NULL,
  platform          VARCHAR(64)  NOT NULL,
  app_version       VARCHAR(64)  NOT NULL,
  status            VARCHAR(16)  NOT NULL, -- 'pending' | 'claimed' | 'completed'
  user_id           CHAR(36)     NULL,
  host_id           CHAR(36)     NULL,
  ip                VARCHAR(64)  NULL,
  created_at        DATETIME(3)  NOT NULL,
  expires_at        DATETIME(3)  NOT NULL,
  PRIMARY KEY (id),
  KEY pairings_code_status (code, status),
  KEY pairings_ip_created (ip, created_at),
  KEY pairings_user (user_id)
);
