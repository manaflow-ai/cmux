// How a category's groups show (Lucas's settings overhaul, 2026-11): each row's level
// (rowLevelsData.ts) keeps main rows on the card, puts "more" rows under the card's More Options
// row (MoreOptions.tsx, opening in place) and leaves "hidden" rows off the page (search, the palette,
// the CLI and cmux.json still have them). Small cards merge into one.
import type { CategoryGroup } from "./categories";
import type { SchemaRow } from "./schema";
import { ROW_LEVELS } from "./rowLevelsData";

/** A card as the page draws it: its main rows, the rows behind More Options, and whether
 * it is a merged card that draws no title. */
export type ArrangedGroup = CategoryGroup & { more?: SchemaRow[]; untitled?: boolean };

export function arrangeGroups(
  categoryId: string,
  groups: readonly CategoryGroup[],
  focus: string | null = null,
): ArrangedGroup[] {
  // A link to a hidden row (a search result, Return in search) shows it behind its card's More
  // Options, which the link opens, so the link never lands on a page without its row.
  const level = (row: SchemaRow) => {
    const own = ROW_LEVELS.levels[row.key];
    return own === "hidden" && row.key === focus ? "more" : own;
  };
  const sorted: ArrangedGroup[] = groups.map((group) => ({
    ...group,
    rows: group.rows.filter((row) => !level(row)),
    more: group.rows.filter((row) => level(row) === "more"),
  }));
  const byKey = new Map(sorted.map((group) => [group.key, group]));
  const gone = new Set<string>();
  for (const merge of ROW_LEVELS.merges[categoryId] ?? []) {
    const into = byKey.get(merge.into);
    if (!into) continue;
    for (const key of merge.from) {
      const from = byKey.get(key);
      if (!from || from === into) continue;
      into.rows = [...into.rows, ...from.rows];
      into.more = [...(into.more ?? []), ...(from.more ?? [])];
      gone.add(key);
    }
    if (merge.title === "") into.untitled = true;
    else into.title = { text: merge.title, key: null };
  }
  return sorted.filter((group) => !gone.has(group.key) && (group.rows.length > 0 || (group.more?.length ?? 0) > 0));
}
