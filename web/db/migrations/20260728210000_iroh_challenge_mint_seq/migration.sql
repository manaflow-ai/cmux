-- Strictly monotonic challenge issuance order for the registration staleness
-- gate. Challenge mint times come from a millisecond clock, so two concurrent
-- challenges can tie on created_at; a timestamp-only gate then lets the STALE
-- one land second and overwrite the newer registration's mutable fields. The
-- sequence breaks the tie deterministically in issuance order. bigserial also
-- backfills existing (short-lived, 10-minute-expiry) challenge rows.
ALTER TABLE iroh_registration_challenges
  ADD COLUMN mint_seq bigserial NOT NULL;

-- The issuance sequence of the challenge whose registration last landed on the
-- slot, paired with registered_at as the (timestamp, sequence) staleness
-- high-water mark. 0 = the row predates the column, so any real challenge
-- (mint_seq >= 1) beats it on a timestamp tie.
ALTER TABLE iroh_endpoint_bindings
  ADD COLUMN registered_mint_seq bigint NOT NULL DEFAULT 0;
