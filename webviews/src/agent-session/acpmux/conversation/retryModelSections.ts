// Retry's model menu (TurnRows.tsx): a harness's models in two sections, as Claude Code lists them
// mixed (its releases, its own aliases such as "Opus" and modes such as "Opus plan"). Releases
// first, under Models; the version-less aliases and modes after them. A model the harness offers
// twice is one row: the same id, the alias the harness named as a release beside that release
// (`release`, modelCatalogData.ts foldAliases), or two rows of the same name. What a bare alias
// runs is never guessed: only the harness says it (Claude Code's `haiku` changes with its version).

/** A model Retry can move the chat to; `release` names the release an alias runs, when known. */
export type RetryModel = { id: string; name: string; release?: string };

/** Releases (`models`) and the harness's aliases and modes (`aliases`), each in list order. */
export type RetrySections = { models: RetryModel[]; aliases: RetryModel[] };

/** "Claude Opus 5.5" and "Opus 5.5" are one name. */
const nameKey = (name: string) =>
  name
    .replace(/^claude\s+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

/** A name that states a version before any " · " detail ("Fable 5.1 · 1M context", "GPT-6-Astra"). */
const isRelease = (model: RetryModel) => model.release !== undefined || /\d/.test(model.name.split(" · ")[0] ?? "");

/**
 * Splits `models` into sections, one row per model. Of two rows for the same model the first stays,
 * unless the second is `current`, so the model the chat runs is always the checked row.
 */
export function retryModelSections(models: readonly RetryModel[], current: string | undefined): RetrySections {
  const kept: RetryModel[] = [];
  const same = (a: RetryModel, b: RetryModel) =>
    a.id === b.id || (a.release ?? a.id) === (b.release ?? b.id) || nameKey(a.name) === nameKey(b.name);
  for (const model of models) {
    const index = kept.findIndex((other) => same(other, model));
    if (index < 0) kept.push(model);
    else if (model.id === current && kept[index]!.id !== current) kept[index] = model;
  }
  return { models: kept.filter(isRelease), aliases: kept.filter((model) => !isRelease(model)) };
}
