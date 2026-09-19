-- Rows created before Cloud VM slugs were introduced must still have a
-- stable, addressable name. UUID-derived suffixes are deterministic and
-- collision-free, while the three fixed words preserve the URL-safe slug
-- grammar used by new rows.
UPDATE "cloud_vms"
SET "slug" = 'legacy-cloud-vm-' || replace("id"::text, '-', '')
WHERE "slug" IS NULL;
