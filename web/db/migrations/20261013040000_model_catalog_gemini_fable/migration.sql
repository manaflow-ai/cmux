-- Brings a database that ran 20261007120000_model_catalog before its seed
-- changed up to that seed: the Gemini CLI harness (cx-miuo) and Claude Code's
-- `fable` alias (cx-uxeb, `claude --model fable` runs Fable 5.1 on 2.1.295).
-- Data only and idempotent: a row a curator added or edited keeps its own
-- value. The next publish serves the change.
INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES
  ('harness', 'gemini', NULL, '{"id":"gemini","docsUrl":"https://github.com/google-gemini/gemini-cli","name":"Gemini CLI","brand":"gemini","families":["gemini"],"modelSource":"catalog","sources":[{"provider":"google","include":["gemini-"],"exclude":["gemini-embedding","gemini-omni","gemini-2.5-computer-use","*-latest","*-customtools","*-live-preview","*-translate-preview","*-tts","*-tts-preview","*-image","*-image-preview"],"minReleaseDate":"2025-06-01"}],"defaultModel":"gemini-3.1-pro-preview","dropEfforts":["none","minimal","low","medium","high","xhigh","max"],"shortNamePrefix":"Gemini ","familyNames":{"gemini-pro":"Pro","gemini-flash":"Flash","gemini-flash-lite":"Flash Lite"},"position":5}'::jsonb, 'seed')
ON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;

UPDATE "catalog_overrides"
SET "value" = jsonb_set("value", '{familyAliases,claude-fable}', '"fable"'::jsonb, true), "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'claude' AND "author" = 'seed'
  AND "value" ? 'familyAliases' AND NOT ("value" -> 'familyAliases') ? 'claude-fable';
