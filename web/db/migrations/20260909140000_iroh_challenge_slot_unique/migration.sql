-- Registration challenges are ephemeral per-slot state. Retain the newest
-- unconsumed challenge for each slot while removing the historical rows that
-- accumulated before consumed challenges were deleted on registration.
WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY user_id, client_namespace, device_uuid, tag
      ORDER BY (consumed_at IS NULL) DESC, created_at DESC, id DESC
    ) AS row_number
  FROM iroh_registration_challenges
)
DELETE FROM iroh_registration_challenges AS challenge
USING ranked
WHERE challenge.id = ranked.id
  AND ranked.row_number > 1;
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_registration_challenges_slot_unique"
  ON "iroh_registration_challenges"
    ("user_id", "client_namespace", "device_uuid", "tag");
