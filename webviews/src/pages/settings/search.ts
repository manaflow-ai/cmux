// Search across every category by title, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere. "Show only
// changed" (P4) uses the same listing: the rows whose value differs from the default.
import { categories, type Category, type CategoryGroup } from "./categories";
import { valueText } from "./format";
import type { SchemaRow } from "./schema";
import { text } from "./strings";

export function queryTerms(query: string): string[] {
  return query.toLowerCase().split(/\s+/).filter(Boolean);
}

export function rowMatches(row: SchemaRow, value: unknown, terms: string[]): boolean {
  if (terms.length === 0) return false;
  const haystack = [
    text(row.title),
    row.title.text,
    text(row.help),
    row.help?.text ?? "",
    row.key,
    ...row.keywords,
    valueText(row, value),
  ]
    .join("\n")
    .toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export type SearchGroup = { category: Category; groups: CategoryGroup[]; rows: SchemaRow[] };

export type ListFilter = {
  query: string;
  /** Only rows a user changed (`customized`). */
  changedOnly?: boolean;
  valueOf(key: string): unknown;
  isChanged?(key: string): boolean;
};

/** Matching rows of every category, in navigation order; an empty query with changedOnly lists
 * every changed row. */
export function filterRows({ query, changedOnly = false, valueOf, isChanged }: ListFilter): SearchGroup[] {
  const terms = queryTerms(query);
  const keep = (row: SchemaRow) =>
    (terms.length === 0 ? changedOnly : rowMatches(row, valueOf(row.key), terms)) &&
    (!changedOnly || (isChanged?.(row.key) ?? false));
  return categories
    .map((category) => {
      const groups = category.groups
        .map((group) => ({ ...group, rows: group.rows.filter(keep) }))
        .filter((group) => group.rows.length > 0);
      return { category, groups, rows: groups.flatMap((group) => group.rows) };
    })
    .filter((result) => result.rows.length > 0);
}

export function searchRows(query: string, valueOf: (key: string) => unknown): SearchGroup[] {
  return filterRows({ query, valueOf });
}
