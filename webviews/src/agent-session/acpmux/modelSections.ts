// The model picker's order (cx-jqkx): the agent's default, then each family's newest models, then
// every older version, newest first. The picker shows the first two sections and folds the older
// versions under one "Older models" row, so a new release is always in view.
import { isDefaultChoice } from "./defaultChoice";
import { classify } from "./modelTaxonomy";

/** `family` is the catalog's ("Opus", "Sol"); without one the name and id decide it. */
export type SectionModel = { id: string; name: string; family?: string };

/** The version a model's name states before any " · " detail ("Opus 5.5 · 1M context" is [5, 5]);
 *  none for "Opus", "Opus · 1M context" or "Opus plan". */
function versionOf(model: SectionModel): number[] {
  const match = /\d+(?:\.\d+)*/.exec(model.name.split(" · ")[0] ?? "");
  return match ? match[0].split(".").map(Number) : [];
}

function compare(a: number[], b: number[]): number {
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] ?? -1) - (b[index] ?? -1);
    if (difference !== 0) return difference;
  }
  return 0;
}

/**
 * Splits a harness's models into `latest` (the defaults, then every model of its family's newest
 * version or with no version, in list order) and `older` (the rest, newest first, then list order).
 */
export function modelSections<T extends SectionModel>(
  models: readonly T[],
  harnessName: string,
): { latest: T[]; older: T[] } {
  const seen = new Set<string>();
  const unique = models.filter((model) => !seen.has(model.id) && seen.add(model.id));
  const entries = unique.map((model, order) => {
    const family = (model.family ?? classify(model, harnessName).family).toLowerCase();
    return { model, order, family, version: versionOf(model) };
  });
  const newest = new Map<string, number[]>();
  for (const entry of entries) {
    if (isDefaultChoice(entry.model) || entry.version.length === 0) continue;
    const best = newest.get(entry.family);
    if (!best || compare(entry.version, best) > 0) newest.set(entry.family, entry.version);
  }
  const isLatest = (entry: (typeof entries)[number]) =>
    entry.version.length === 0 || compare(entry.version, newest.get(entry.family) ?? []) === 0;
  const defaults = entries.filter((entry) => isDefaultChoice(entry.model));
  const rest = entries.filter((entry) => !isDefaultChoice(entry.model));
  return {
    latest: [...defaults, ...rest.filter(isLatest)].map((entry) => entry.model),
    older: rest
      .filter((entry) => !isLatest(entry))
      .sort((a, b) => compare(b.version, a.version) || a.order - b.order)
      .map((entry) => entry.model),
  };
}
