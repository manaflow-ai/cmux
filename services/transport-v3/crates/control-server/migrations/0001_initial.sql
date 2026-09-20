CREATE TABLE transport_v3_teams (
  team_id TEXT PRIMARY KEY, revision BIGINT NOT NULL DEFAULT 1 CHECK(revision > 0),
  cedar TEXT NOT NULL CHECK(octet_length(cedar) <= 65536)
);
CREATE TABLE transport_v3_devices (
  team_id TEXT NOT NULL REFERENCES transport_v3_teams(team_id), peer_id TEXT NOT NULL,
  device_id UUID NOT NULL, owner_user_id TEXT NOT NULL, active BOOLEAN NOT NULL DEFAULT TRUE,
  tags JSONB NOT NULL DEFAULT '[]',
  lease JSONB NOT NULL DEFAULT '{"offline":{"mode":"bounded","seconds":300},"renew_every_seconds":30}',
  PRIMARY KEY(team_id,peer_id), UNIQUE(team_id,device_id), UNIQUE(peer_id)
);
CREATE TABLE transport_v3_nonces (
  user_id TEXT NOT NULL, nonce UUID NOT NULL, expires_at BIGINT NOT NULL,
  PRIMARY KEY(user_id,nonce)
);
CREATE INDEX transport_v3_nonces_expiry ON transport_v3_nonces(expires_at);
CREATE TABLE transport_v3_events (
  sequence BIGSERIAL PRIMARY KEY, team_id TEXT NOT NULL REFERENCES transport_v3_teams(team_id),
  revision BIGINT NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, peer_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX transport_v3_events_team_sequence ON transport_v3_events(team_id,sequence);
CREATE TABLE transport_v3_relays (
  peer_id TEXT PRIMARY KEY, region TEXT NOT NULL, addresses JSONB NOT NULL, active BOOLEAN NOT NULL DEFAULT TRUE
);
