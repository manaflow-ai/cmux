-- Update existing seed data without replacing curator-owned rows or explicit ordering.
-- An array preserves display order through JSONB storage; object keys do not.
UPDATE "catalog_overrides"
SET "value" = jsonb_set(
  jsonb_set("value", '{familyNames}',
    COALESCE("value" -> 'familyNames', '{}'::jsonb)
      || '{"gemini-carbon":"Carbon","gemini-hydrogen":"Hydrogen"}'::jsonb),
  '{familyOrder}',
  '["gemini-carbon","gemini-hydrogen","gemini-pro","gemini-flash","gemini-flash-lite"]'::jsonb
), "updated_at" = now()
WHERE "kind" = 'harness' AND "harness_id" = 'gemini' AND "author" = 'seed'
  AND NOT ("value" ? 'familyOrder');
