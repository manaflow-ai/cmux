-- Curated model catalog (GET /api/models/v1). Additive: three new tables that
-- no existing reader or writer uses, so old app code runs unchanged. The
-- catalog_overrides seed is web/services/model-catalog/overrides.ts as rows
-- (bun tools/model-catalog-seed-sql.ts).
CREATE TABLE IF NOT EXISTS "models_dev_snapshots" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
	"content_hash" text NOT NULL,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL,
	"raw" jsonb NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS "models_dev_snapshots_content_hash_unique" ON "models_dev_snapshots" ("content_hash");
CREATE INDEX IF NOT EXISTS "models_dev_snapshots_fetched_at_idx" ON "models_dev_snapshots" ("fetched_at" DESC);

CREATE TABLE IF NOT EXISTS "catalog_overrides" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"kind" text NOT NULL,
	"harness_id" text NOT NULL,
	"model_id" text,
	"value" jsonb NOT NULL,
	"author" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"active" boolean DEFAULT true NOT NULL,
	CONSTRAINT "catalog_overrides_target_unique" UNIQUE NULLS NOT DISTINCT ("kind", "harness_id", "model_id"),
	CONSTRAINT "catalog_overrides_kind_check" CHECK ("kind" in ('harness', 'model')),
	CONSTRAINT "catalog_overrides_model_id_check" CHECK (("kind" = 'model') = ("model_id" is not null))
);

CREATE TABLE IF NOT EXISTS "catalog_versions" (
	"version" integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
	"content_hash" text NOT NULL,
	"catalog" jsonb NOT NULL,
	"published_at" timestamp with time zone DEFAULT now() NOT NULL,
	"published_by" text NOT NULL,
	"source_snapshot_id" bigint,
	CONSTRAINT "catalog_versions_source_snapshot_id_models_dev_snapshots_id_fk" FOREIGN KEY ("source_snapshot_id") REFERENCES "models_dev_snapshots" ("id")
);
CREATE INDEX IF NOT EXISTS "catalog_versions_published_at_idx" ON "catalog_versions" ("published_at" DESC);

INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES
  ('harness', 'claude', NULL, '{"id":"claude","docsUrl":"https://docs.claude.com/en/docs/claude-code/setup","name":"Claude Code","brand":"claude","families":["claude"],"modelSource":"catalog","sources":[{"provider":"anthropic","include":["claude-"],"exclude":["*-20[0-9][0-9][0-9][0-9][0-9][0-9]","claude-3"]}],"defaultModel":"claude-sonnet-5","shortNamePrefix":"Claude ","familyNames":{"claude-fable":"Fable","claude-opus":"Opus","claude-sonnet":"Sonnet","claude-haiku":"Haiku"},"familyAliases":{"claude-opus":"opus","claude-sonnet":"sonnet","claude-haiku":"haiku"},"position":0}'::jsonb, 'seed'),
  ('harness', 'codex', NULL, '{"id":"codex","docsUrl":"https://developers.openai.com/codex/cli","name":"Codex","brand":"openai","families":["codex"],"modelSource":"catalog","sources":[{"provider":"openai","include":["gpt-"],"exclude":["gpt-oss","gpt-realtime","gpt-image","gpt-audio","*-latest","*-nano","*-pro"],"minReleaseDate":"2026-04-01"}],"defaultModel":"gpt-5.5","defaultEffort":"medium","dropEfforts":["none"],"familyNames":{"gpt-sol":"Sol","gpt-astra":"Astra","gpt-luna":"Luna","gpt-terra":"Terra","gpt":"GPT","gpt-codex":"GPT Codex","gpt-mini":"GPT mini"},"position":1}'::jsonb, 'seed'),
  ('harness', 'opencode', NULL, '{"id":"opencode","docsUrl":"https://opencode.ai/docs","name":"OpenCode","brand":"opencode","families":["opencode"],"modelSource":"probe","position":2}'::jsonb, 'seed'),
  ('harness', 'pi', NULL, '{"id":"pi","docsUrl":"https://github.com/earendil-works/pi","name":"Pi","brand":"pi","families":["pi"],"modelSource":"probe","position":3}'::jsonb, 'seed'),
  ('harness', 'vercel-ai-gateway', NULL, '{"id":"vercel-ai-gateway","docsUrl":"https://vercel.com/docs/ai-gateway","name":"Vercel AI Gateway","brand":"vercel","families":["vercel-ai-gateway"],"modelSource":"catalog","sources":[{"provider":"vercel","include":["anthropic/claude-","openai/gpt-5","openai/gpt-6","google/gemini-3","xai/grok-","deepseek/","moonshotai/","zai/","alibaba/qwen3-coder"],"exclude":["*-20[0-9][0-9][0-9][0-9][0-9][0-9]","*-[0-9][0-9][0-9][0-9]","*-fast","*-highspeed","*-flashx","*-exp","*-pro","*-nano","*-chat-latest","*-tts","*-image","*-image-preview","*-live","*-live-extended-thinking","*-transcribe"],"minReleaseDate":"2026-01-01"}],"defaultModel":"anthropic/claude-sonnet-5","groupByProvider":true,"position":4}'::jsonb, 'seed')
ON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;
