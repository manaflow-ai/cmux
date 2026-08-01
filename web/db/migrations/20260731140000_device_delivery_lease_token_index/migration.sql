-- releaseDeviceDeliveryTargets locates claimed rows by lease token after
-- every completed push; without an index that is a table-wide scan that grows
-- with all registered devices. Partial: only rows claimed by an in-flight
-- delivery carry a token, so the index stays a handful of entries.
CREATE INDEX IF NOT EXISTS "device_tokens_delivery_lease_token_idx"
  ON "device_tokens" ("delivery_lease_token")
  WHERE "delivery_lease_token" is not null;
