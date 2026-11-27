-- Brings a database seeded before overrides.ts moved the default models up to
-- that seed (cx-qtmy2, 2026-10-13): new Claude Code chats start on
-- claude-opus-5-5 and new Codex chats on gpt-6.1-sol, both at medium effort.
-- Data only and idempotent: a row a curator edited (author other than seed, or
-- a default other than the old seed value) keeps its own value. The next
-- publish serves the change.
UPDATE "catalog_overrides"
SET "value" = "value" || '{"defaultModel":"claude-opus-5-5","defaultEffort":"medium"}'::jsonb, "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'claude' AND "author" = 'seed'
  AND "value" ->> 'defaultModel' = 'claude-sonnet-5' AND NOT "value" ? 'defaultEffort';

UPDATE "catalog_overrides"
SET "value" = jsonb_set("value", '{defaultModel}', '"gpt-6.1-sol"'::jsonb, true), "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'codex' AND "author" = 'seed'
  AND "value" ->> 'defaultModel' = 'gpt-5.5';
