// Retry's model menu (RetryModelMenu.tsx): a harness's models in the composer model menu's order
// (Leo 2026-10-20: "why is this still unstyled", the list showed Opus 5.5, Sonnet 5.5 and Haiku 5.5
// twice and every old release in one column). The harness's reported menu comes
// first, else each family's newest; every other model folds under More models (relevantModels.ts),
// as the composer's picker folds them. A model the harness offers twice is one row: the same id,
// the alias the harness named as a release beside that release (`release`, modelCatalogData.ts
// foldAliases), or two rows of the same name. What a bare alias runs is never guessed: only the
// harness says it (Claude Code's `haiku` changes with its version).
import { relevantModelSections } from "../relevantModels";

/** A model Retry can move the chat to; `release` names the release an alias runs, when known. */
export type RetryModel = { id: string; name: string; release?: string; family?: string; unavailable?: string };

/** The rows shown at once (`latest`) and the ones folded under More models (`more`), each in order. */
export type RetrySections = { latest: RetryModel[]; more: RetryModel[] };

/** "Claude Opus 5.5" and "Opus 5.5" are one name. */
const nameKey = (name: string) =>
  name
    .replace(/^claude\s+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

const sameModel = (a: RetryModel, b: RetryModel) =>
  a.id === b.id || (a.release ?? a.id) === (b.release ?? b.id) || nameKey(a.name) === nameKey(b.name);

/** Each model once, in list order. Of two rows for the same model the first stays, unless the second
 *  is `current`, so the model the chat runs is always the checked row. */
export function uniqueRetryModels(models: readonly RetryModel[], current: string | undefined): RetryModel[] {
  const kept: RetryModel[] = [];
  for (const model of models) {
    const index = kept.findIndex((other) => sameModel(other, model));
    if (index < 0) kept.push(model);
    else if (model.id === current && kept[index]!.id !== current) kept[index] = model;
  }
  return kept;
}

/**
 * Splits `models` into the rows shown at once and the ones under More models, one row per model.
 * `top` is the same harness-reported menu the composer uses. Without a report, both menus
 * show the newest available family members. With a report the running model keeps its row; without
 * one a running older model stays under More models.
 */
export function retryModelSections(
  models: readonly RetryModel[],
  current: string | undefined,
  _harness = "",
  top?: readonly string[],
): RetrySections {
  const isCurrent = (model: RetryModel) =>
    typeof current === "string" && current.length > 0 && (model.id === current || model.release === current);
  const available = models.filter((model) => isCurrent(model) || !model.unavailable);
  const unique = uniqueRetryModels(available, current);
  // A running model can be temporarily unavailable to the probe while still being the only
  // valid checked choice for this turn. Treat just that row as available for grouping; App.tsx
  // filters unavailable alternatives before constructing this list.
  const candidates = unique.map((model) =>
    isCurrent(model) && model.unavailable ? { ...model, unavailable: undefined } : model,
  );
  // A deduplicated row still represents each provider/alias identity the harness reported.
  const mappedTop = top?.flatMap((id) => {
    const reported = available.find((model) => model.id === id || model.release === id);
    const kept = reported && unique.find((model) => sameModel(model, reported));
    return kept ? [kept.id] : [];
  });
  const { shown, more } = relevantModelSections(candidates, mappedTop, current);
  const original = new Map(unique.map((model) => [model.id, model]));
  return {
    latest: shown.map((model) => original.get(model.id) ?? model),
    more: more.map((model) => original.get(model.id) ?? model),
  };
}
