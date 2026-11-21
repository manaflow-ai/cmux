-- Brings a database seeded before 2026-11-20 up to overrides.ts (cmux#48354): new Codex chats
-- start on gpt-6.2-sol at high effort, what `codex` in a terminal runs; other Codex models keep
-- medium. Data only and idempotent: a row a curator edited (author is not 'seed', or a default
-- other than the old seed value) keeps its own value. The next publish serves the change.
UPDATE "catalog_overrides"
SET "value" = jsonb_set(
      jsonb_set("value", '{defaultModel}', '"gpt-6.2-sol"'::jsonb, true),
      '{models}',
      COALESCE("value" -> 'models', '{}'::jsonb)
        || jsonb_build_object('gpt-6.2-sol',
             COALESCE("value" -> 'models' -> 'gpt-6.2-sol', '{}'::jsonb) || '{"defaultEffort":"high"}'::jsonb),
      true),
    "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'codex' AND "author" = 'seed'
  AND "value" ->> 'defaultModel' = 'gpt-6.1-sol';
