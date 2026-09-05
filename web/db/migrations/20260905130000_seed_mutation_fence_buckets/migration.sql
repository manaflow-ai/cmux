-- Pre-create the bounded cross-runtime lock fence set. Row and hybrid lock
-- modes fail closed when their bucket is absent, so this migration must land
-- before direct Worker traffic is enabled.
INSERT INTO "account_mutation_fences" ("lock_key")
SELECT 'bucket:' || series::text
FROM generate_series(0, 4095) AS series
ON CONFLICT ("lock_key") DO NOTHING;
