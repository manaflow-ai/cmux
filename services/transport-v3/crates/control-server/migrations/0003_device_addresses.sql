ALTER TABLE transport_v3_devices
  ADD COLUMN addresses JSONB NOT NULL DEFAULT '[]';

ALTER TABLE transport_v3_events ADD COLUMN team_sequence BIGINT;
WITH numbered AS (
  SELECT sequence, row_number() OVER (PARTITION BY team_id ORDER BY sequence) AS n
  FROM transport_v3_events
)
UPDATE transport_v3_events e SET team_sequence = numbered.n FROM numbered WHERE e.sequence = numbered.sequence;
ALTER TABLE transport_v3_events ALTER COLUMN team_sequence SET NOT NULL;
CREATE UNIQUE INDEX transport_v3_events_team_local_sequence ON transport_v3_events(team_id, team_sequence);
