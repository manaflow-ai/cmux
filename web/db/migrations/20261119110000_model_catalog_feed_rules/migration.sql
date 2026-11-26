-- Brings a database seeded before 2026-11-19 up to overrides.ts (user 2026-11-19: "gemini
-- neon didn't automatically appear in model picker for us"): Gemini CLI runs any Gemini API
-- id (`runsAnyModel`, so pickers offer models its fixed ACP menu does not name) and groups
-- Gemini 4's "gemini" feed family; the AI Gateway lists every Gemini and GPT generation, not
-- only 3.x/5.x/6.x. Data only and idempotent: a row a curator edited (author is not 'seed')
-- keeps its own value. The next publish serves the change.
UPDATE "catalog_overrides"
SET "value" = jsonb_set(jsonb_set("value", '{runsAnyModel}', 'true'::jsonb, true),
                        '{familyNames}', '{"gemini":"Gemini","gemini-pro":"Pro","gemini-flash":"Flash","gemini-flash-lite":"Flash Lite"}'::jsonb, true),
    "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'gemini' AND "author" = 'seed'
  AND NOT ("value" ? 'runsAnyModel');

UPDATE "catalog_overrides"
SET "value" = jsonb_set("value", '{sources}', '[{"provider":"vercel","include":["anthropic/claude-","openai/gpt-","google/gemini-","xai/grok-","deepseek/","moonshotai/","zai/","alibaba/qwen3-coder"],"exclude":["*-20[0-9][0-9][0-9][0-9][0-9][0-9]","*-[0-9][0-9][0-9][0-9]","openai/gpt-oss","openai/gpt-realtime","openai/gpt-live","openai/gpt-image","openai/gpt-audio","google/gemini-embedding","*-fast","*-highspeed","*-flashx","*-exp","*-pro","*-nano","*-chat-latest","*-tts","*-image","*-image-preview","*-live","*-live-extended-thinking","*-transcribe"],"minReleaseDate":"2026-01-01"}]'::jsonb, true),
    "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'vercel-ai-gateway' AND "author" = 'seed'
  AND "value" -> 'sources' -> 0 -> 'include' ? 'google/gemini-3';
