// Retry's model menu (RetryModelMenu.tsx): a harness's models in the composer model menu's order
// (Leo 2026-10-20: "why is this still unstyled", the list showed Opus 5.5, Sonnet 5.5 and Haiku 5.5
// twice and every old release in one column). The harness's curated top models (topModels/) come
// first, else each family's newest; every other model folds under More models (modelSections.ts),
// as the composer's picker folds them. A model the harness offers twice is one row: the same id,
// the alias the harness named as a release beside that release (`release`, modelCatalogData.ts
// foldAliases), or two rows of the same name. What a bare alias runs is never guessed: only the
// harness says it (Claude Code's `haiku` changes with its version).
import { curatedSections, modelSections } from "../modelSections";

/** A model Retry can move the chat to; `release` names the release an alias runs, when known. */
export type RetryModel = { id: string; name: string; release?: string };

/** The rows shown at once (`latest`) and the ones folded under More models (`more`), each in order. */
export type RetrySections = { latest: RetryModel[]; more: RetryModel[] };

/** "Claude Opus 5.5" and "Opus 5.5" are one name. */
const nameKey = (name: string) =>
  name
    .replace(/^claude\s+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

/** Each model once, in list order. Of two rows for the same model the first stays, unless the second
 *  is `current`, so the model the chat runs is always the checked row. */
export function uniqueRetryModels(models: readonly RetryModel[], current: string | undefined): RetryModel[] {
  const kept: RetryModel[] = [];
  const same = (a: RetryModel, b: RetryModel) =>
    a.id === b.id || (a.release ?? a.id) === (b.release ?? b.id) || nameKey(a.name) === nameKey(b.name);
  for (const model of models) {
    const index = kept.findIndex((other) => same(other, model));
    if (index < 0) kept.push(model);
    else if (model.id === current && kept[index]!.id !== current) kept[index] = model;
  }
  return kept;
}

/**
 * Splits `models` into the rows shown at once and the ones under More models, one row per model.
 * `harness` is the harness's name (it decides a model's family when the name alone does not);
 * `top` its curated list. The model the chat runs is never folded: a folded one is listed last
 * among the shown rows, as the composer's picker lists it.
 */
export function retryModelSections(
  models: readonly RetryModel[],
  current: string | undefined,
  harness = "",
  top?: readonly string[],
): RetrySections {
  const { latest, older } = curatedSections(modelSections(uniqueRetryModels(models, current), harness), top);
  const runs = older.find((model) => model.id === current);
  if (!runs) return { latest, more: older };
  return { latest: [...latest, runs], more: older.filter((model) => model !== runs) };
}
