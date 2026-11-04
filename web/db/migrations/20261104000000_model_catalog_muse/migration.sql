-- Adds Muse Code's catalog identity and official Spark model rows for databases
-- that were seeded before Gemini/Muse support. Data only and idempotent: a
-- curator override keeps its own value.
INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES
  ('harness', 'muse', NULL, '{"id":"muse","docsUrl":"https://dev.meta.ai/docs/muse-code","name":"Muse Code","brand":"meta","families":["muse"],"modelSource":"catalog","defaultModel":"muse-spark-1.3","familyNames":{"muse-spark":"Spark"},"position":6}'::jsonb, 'seed'),
  ('model', 'muse', 'muse-spark-1.3', '{"name":"Muse Spark 1.3","shortName":"Spark 1.3","family":"Spark","provider":"meta"}'::jsonb, 'seed'),
  ('model', 'muse', 'muse-spark-1.3-contributor', '{"name":"Muse Spark 1.3 Contributor","shortName":"Spark 1.3 Contributor","family":"Spark","provider":"meta"}'::jsonb, 'seed'),
  ('model', 'muse', 'muse-spark-1.2', '{"name":"Muse Spark 1.2","shortName":"Spark 1.2","family":"Spark","provider":"meta"}'::jsonb, 'seed'),
  ('model', 'muse', 'muse-spark-1.1', '{"name":"Muse Spark 1.1","shortName":"Spark 1.1","family":"Spark","provider":"meta"}'::jsonb, 'seed')
ON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;
