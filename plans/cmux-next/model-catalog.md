# Model catalog: where the picker's models come from

Bead cx-jqkx (2026-10-09). Lawrence's Claude Code picker listed Default, Opus 4.5 ... Opus 4.7 and
no Opus 5.5 or Haiku 5.5. The catalog had Opus 5.5, but the picker sorted oldest first in a 300 px
list, so the newest models sat below the fold; Haiku 5.5 was not in the catalog at all. This file
is the long-term rule set so a new release never again needs a cmux update to show. The Start
Agent launcher (cx-hkat) reuses the same picker and rules.

## Authority, in order

1. **The harness.** Every model the agent reports is shown: the ACP session's model config option
   (its choices and its current value), ACP `models.availableModels`, and acpmux's
   `_acpmux/models` list. Nothing else may hide one of them. A user `hidden` override in cmux.json
   `agentPane.models` is the only exception.
2. **Claude Code reports its own list.** acpmux's live model probe (`live_models/claude.rs`,
   hq-21, ef266b891d81) runs the harness's own `claude` in stream-json mode and reads
   `list_models`, else the `initialize` reply's `models` (`value`, `displayName`, `description`,
   `resolvedModel`). Claude Code 2.1.295 reports `default`, `opus`, `claude-fable-5-1[1m]`,
   `sonnet`, `haiku`, resolving to Opus 5.5, Fable 5.1, Sonnet 5.5 and Haiku 5.5. That list is the
   one source; `_acpmux/models` serves it, the static `claude_stdio` list stands in only before
   the first probe answers.
3. **Only the harness says what an alias runs.** An alias's target depends on the installed
   harness: Claude Code 2.1.287's `haiku` is Haiku 4.5, 2.1.295's is Haiku 5.5. acpmux's live list keeps the
   concrete id from the reply (`resolvedModel`) and names the choice by Claude Code's own words. The picker never infers an alias's target from the catalog. When the harness names
   an alias as a catalog release ("opus" named "Opus 5.5"), the alias takes that release's row,
   with its catalog metadata, so a pick follows the harness's newest model; any other alias stays
   its own row under the harness's name. The catalog's `aliases` field (`familyAliases` in
   web/services/model-catalog/overrides.ts) only serves acpmux's model-id lookups.
4. **The live catalog adds names and metadata.** `GET https://cmux.com/api/models/v1` (models.dev
   projected through the overrides, served from the `catalog_overrides` tables) supplies display
   names, families, context windows, efforts and fast mode. The app host caches it; acpmux reads
   it (`cmux-tui/crates/acpmux/src/catalog`).
5. **The bundled snapshot is the offline fallback.** web/data/model-catalog/snapshot.json and its
   identical copy cmux-tui/crates/acpmux/catalog/models-v1.json are what the picker shows before
   the host answers and while offline. They never hide a harness-reported model. Refresh both with
   `bun tools/refresh-model-catalog-snapshot.ts` in web/ (the 2026-10-09 refresh added
   claude-haiku-5-5 and moved `haiku` to it).

## Picker order and layout

- Default first, then each family's newest models (every variant of the newest version, and any
  model that names no version), in harness order. Older versions fold under one "Older models"
  row, newest first; a search looks through all models. Starred models sit above everything.
- One harness: no harness column. One star column, at the right of each row. The check and the
  ⌘1-⌘4 hint have fixed slots, so the hints form one column. The catalog refresh button sits in
  the search row.

## Open item

The `fable` alias is not in the catalog yet: `catalog_overrides` is seeded by migration
20261007120000, and web/tests/model-catalog.test.ts requires that seed to equal overrides.ts, so
adding `"claude-fable": "fable"` needs a data migration for databases already seeded. Rule 3 makes
the alias field matter less: Fable's latest entry comes from Claude Code's own report.
