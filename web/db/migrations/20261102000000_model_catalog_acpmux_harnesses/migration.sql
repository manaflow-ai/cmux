-- Brings a database that ran 20261007120000_model_catalog before its seed
-- changed up to that seed: every harness acpmux runs that the catalog did not
-- name (Prime Intellect, oh-my-pi, Grok, Cursor, Hermes Agent, DeepSeek), so the
-- model picker lists them before they are installed. Data only and idempotent:
-- a row a curator added keeps its own value. The next publish serves the change.
INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES
  ('harness', 'prime', NULL, '{"id":"prime","docsUrl":"https://github.com/PrimeIntellect-ai/prime-agent","name":"Prime Intellect","brand":"prime","families":["prime"],"modelSource":"probe","position":6}'::jsonb, 'seed'),
  ('harness', 'omp', NULL, '{"id":"omp","docsUrl":"https://github.com/can1357/oh-my-pi","name":"oh-my-pi","brand":"omp","families":["omp"],"modelSource":"probe","position":7}'::jsonb, 'seed'),
  ('harness', 'grok', NULL, '{"id":"grok","name":"Grok","brand":"grok","families":["grok"],"modelSource":"probe","position":8}'::jsonb, 'seed'),
  ('harness', 'cursor', NULL, '{"id":"cursor","name":"Cursor","brand":"cursor","families":["cursor"],"modelSource":"probe","position":9}'::jsonb, 'seed'),
  ('harness', 'hermes', NULL, '{"id":"hermes","docsUrl":"https://github.com/NousResearch/hermes-agent","name":"Hermes Agent","brand":"hermes","families":["hermes"],"modelSource":"probe","position":10}'::jsonb, 'seed'),
  ('harness', 'deepseek', NULL, '{"id":"deepseek","name":"DeepSeek","brand":"deepseek","families":["deepseek"],"modelSource":"probe","position":11}'::jsonb, 'seed')
ON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;
