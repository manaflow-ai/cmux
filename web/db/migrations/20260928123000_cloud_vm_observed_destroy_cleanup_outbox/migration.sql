CREATE TABLE "cloud_vm_observed_destroy_cleanups" (
  "vm_id" uuid PRIMARY KEY NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "cleanup" jsonb NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_observed_destroy_cleanups_pending_step" CHECK (
    coalesce(
      jsonb_typeof("cleanup") = 'object'
      AND ("cleanup" - 'modelPlane' - 'homeVolume') = '{}'::jsonb
      AND (
        NOT ("cleanup" ? 'modelPlane')
        OR "cleanup"->'modelPlane' = 'true'::jsonb
      )
      AND (
        NOT ("cleanup" ? 'homeVolume')
        OR (
          jsonb_typeof("cleanup"->'homeVolume') = 'string'
          AND length(btrim("cleanup"->>'homeVolume')) > 0
        )
      )
      AND ("cleanup" ? 'modelPlane' OR "cleanup" ? 'homeVolume'),
      false
    )
  )
);

CREATE INDEX "cloud_vm_observed_destroy_cleanups_updated_idx"
  ON "cloud_vm_observed_destroy_cleanups" ("updated_at", "vm_id")
  WHERE coalesce(
    jsonb_typeof("cleanup") = 'object'
    AND ("cleanup" - 'modelPlane' - 'homeVolume') = '{}'::jsonb
    AND (
      NOT ("cleanup" ? 'modelPlane')
      OR "cleanup"->'modelPlane' = 'true'::jsonb
    )
    AND (
      NOT ("cleanup" ? 'homeVolume')
      OR (
        jsonb_typeof("cleanup"->'homeVolume') = 'string'
        AND length(btrim("cleanup"->>'homeVolume')) > 0
      )
    )
    AND ("cleanup" ? 'modelPlane' OR "cleanup" ? 'homeVolume'),
    false
  );
