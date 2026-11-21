// Curated gallery menus and the bundled catalog share one current-family source.
// Runtime composer and retry menus use the harness's report or relevantModelSections.
import currentFamilies from "../../../../../web/data/model-catalog/current-families.json";

const LISTS: Record<string, readonly string[]> = Object.fromEntries(
  Object.entries(currentFamilies).map(([id, models]) => [id, models.map((model) => model.id)]),
);

/** The curated top model ids for catalog harness `id`, or undefined when it has no list. */
export function topModelsFor(id: string): readonly string[] | undefined {
  const list = LISTS[id];
  return list && list.length > 0 ? list : undefined;
}
