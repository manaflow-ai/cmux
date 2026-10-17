-- Pairing codes grow to 8 characters and pairings gain the approval states
-- 'awaiting_approval' | 'approved' | 'rejected' (status is free-form VARCHAR).
-- rate_events backs the sliding-window limits and lockouts.

ALTER TABLE pairings MODIFY code VARCHAR(8) NOT NULL;

CREATE TABLE IF NOT EXISTS rate_events (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  bucket      VARCHAR(32)     NOT NULL, -- e.g. 'claim_user', 'verify_ip', 'ice'
  k           VARCHAR(128)    NOT NULL, -- user id, ip, principal, or '*' for global
  created_at  DATETIME(3)     NOT NULL,
  PRIMARY KEY (id),
  KEY rate_events_bucket_k_created (bucket, k, created_at),
  KEY rate_events_created (created_at)
);
