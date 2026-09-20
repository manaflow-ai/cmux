ALTER TABLE transport_v3_relays ADD COLUMN feed_token_hash BYTEA;
CREATE INDEX transport_v3_relays_feed_token ON transport_v3_relays(feed_token_hash) WHERE active;
