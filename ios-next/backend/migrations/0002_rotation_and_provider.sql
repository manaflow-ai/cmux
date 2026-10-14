-- Rotation time, separate from revocation, for the 30 s idempotent refresh grace.
ALTER TABLE refresh_tokens ADD COLUMN rotated_at BIGINT NULL;

-- Stack identities use provider `stack:<projectId>` (42 chars).
ALTER TABLE identities MODIFY COLUMN provider VARCHAR(64) NOT NULL;
