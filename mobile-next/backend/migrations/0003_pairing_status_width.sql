-- 'awaiting_approval' is 17 characters; widen pairings.status.
ALTER TABLE pairings MODIFY status VARCHAR(32) NOT NULL;
