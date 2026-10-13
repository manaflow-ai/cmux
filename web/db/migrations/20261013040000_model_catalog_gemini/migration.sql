-- Adds the Gemini CLI harness to the curated model catalog (cx-miuo) for a
-- database that ran 20261007120000_model_catalog before that seed listed it.
-- Data only and idempotent: a database seeded with the row, or a curator who
-- already added one, keeps its own. The next publish serves it.
INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES
  ('harness', 'gemini', NULL, '{"id":"gemini","docsUrl":"https://github.com/google-gemini/gemini-cli","name":"Gemini CLI","brand":"gemini","families":["gemini"],"modelSource":"catalog","sources":[{"provider":"google","include":["gemini-"],"exclude":["gemini-embedding","gemini-omni","gemini-2.5-computer-use","*-latest","*-customtools","*-live-preview","*-translate-preview","*-tts","*-tts-preview","*-image","*-image-preview"],"minReleaseDate":"2025-06-01"}],"defaultModel":"gemini-3.1-pro-preview","dropEfforts":["none","minimal","low","medium","high","xhigh","max"],"shortNamePrefix":"Gemini ","familyNames":{"gemini-pro":"Pro","gemini-flash":"Flash","gemini-flash-lite":"Flash Lite"},"position":5}'::jsonb, 'seed')
ON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;
