-- Iroh is not yet a production rendezvous dependency, so remove every legacy
-- server-held path hint before the relay-only publication policy rolls out.
-- New registrations may repopulate exact managed relay URLs, never direct or
-- private addresses.
UPDATE "iroh_endpoint_bindings"
SET "path_hints" = '[]'::jsonb,
    "path_hints_next_expiry" = NULL
WHERE "path_hints" <> '[]'::jsonb;
--> statement-breakpoint
-- Existing hosts will republish their EndpointID plus managed relay URL on the
-- next heartbeat. Preserve every non-Iroh route byte-for-byte so LAN,
-- Tailscale, and custom-network reconnects remain available during rollout.
UPDATE "device_app_instances"
SET "routes" = '[]'::jsonb
WHERE jsonb_typeof("routes") IS DISTINCT FROM 'array';
--> statement-breakpoint
UPDATE "device_app_instances" AS instance
SET "routes" = COALESCE(
  (
    SELECT jsonb_agg(route.value ORDER BY route.ordinality)
    FROM jsonb_array_elements(instance."routes") WITH ORDINALITY AS route(value, ordinality)
    WHERE route.value ->> 'kind' IS DISTINCT FROM 'iroh'
  ),
  '[]'::jsonb
)
WHERE EXISTS (
  SELECT 1
  FROM jsonb_array_elements(instance."routes") AS route(value)
  WHERE route.value ->> 'kind' = 'iroh'
);
