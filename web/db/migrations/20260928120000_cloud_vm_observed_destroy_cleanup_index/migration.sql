CREATE INDEX CONCURRENTLY IF NOT EXISTS "cloud_vms_observed_destroy_cleanup_idx"
  ON "cloud_vms" ("updated_at", "id")
  WHERE "status" = 'destroyed'
    AND "provider_metadata" ? 'cmuxObservedDestroyCleanup'
    AND jsonb_typeof("provider_metadata"->'cmuxObservedDestroyCleanup') = 'object'
    AND (
      "provider_metadata"->'cmuxObservedDestroyCleanup' @> '{"modelPlane":true}'::jsonb
      OR (
        jsonb_typeof("provider_metadata"->'cmuxObservedDestroyCleanup'->'homeVolume') = 'string'
        AND length(btrim("provider_metadata"->'cmuxObservedDestroyCleanup'->>'homeVolume')) > 0
      )
    );
