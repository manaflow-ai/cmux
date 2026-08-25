-- Re-key the iroh binding slot from the app instance id to (user, device, tag).
-- A reinstall, sign-out/in, or key rotation now overwrites its own slot in place
-- instead of colliding with its past self, so the newest authenticated
-- registration always wins without the operator having to revoke first.
--
-- Before the (user, device, tag) index can be unique, collapse any duplicate
-- active rows that the old app-instance key allowed: keep the most recently seen
-- row per slot, soft-revoke the rest, revoke their pair grants, and bump the LAN
-- discovery generation for every affected account so stale rows stop advertising.
LOCK TABLE iroh_endpoint_bindings IN SHARE ROW EXCLUSIVE MODE;
--> statement-breakpoint
WITH ranked AS (
  SELECT
    id,
    user_id,
    row_number() OVER (
      PARTITION BY user_id, device_uuid, tag
      ORDER BY last_seen_at DESC, registered_at DESC, id DESC
    ) AS rn
  FROM iroh_endpoint_bindings
  WHERE revoked_at IS NULL
),
losers AS (
  SELECT id
  FROM ranked
  WHERE rn > 1
),
revoked AS (
  UPDATE iroh_endpoint_bindings b
  SET
    revoked_at = now(),
    revoked_reason = 'slot_rekey_collapsed',
    direct_port_v4 = NULL,
    direct_port_v6 = NULL,
    path_hints = '[]'::jsonb,
    path_hints_next_expiry = NULL,
    updated_at = now()
  FROM losers
  WHERE b.id = losers.id
  RETURNING b.id, b.user_id
),
grants AS (
  UPDATE iroh_pair_grant_issuances g
  SET revoked_at = now()
  WHERE g.revoked_at IS NULL
    AND (
      g.initiator_binding_id IN (SELECT id FROM revoked)
      OR g.acceptor_binding_id IN (SELECT id FROM revoked)
    )
  RETURNING g.id
)
INSERT INTO iroh_account_security_states (user_id, lan_discovery_generation, created_at, updated_at)
SELECT DISTINCT user_id, 2, now(), now() FROM revoked
ON CONFLICT (user_id) DO UPDATE
  SET lan_discovery_generation = iroh_account_security_states.lan_discovery_generation + 1,
      updated_at = now();
--> statement-breakpoint
DROP INDEX IF EXISTS "iroh_endpoint_bindings_active_app_instance_unique";
--> statement-breakpoint
DROP INDEX IF EXISTS "iroh_endpoint_bindings_user_device_active_idx";
--> statement-breakpoint
CREATE UNIQUE INDEX "iroh_endpoint_bindings_active_slot_unique"
  ON "iroh_endpoint_bindings" ("user_id", "device_uuid", "tag")
  WHERE "revoked_at" IS NULL;
