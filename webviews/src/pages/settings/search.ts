// Search across every category by title, summary, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere. "Show only
// changed" (P4) uses the same listing: the rows whose value differs from the default.
import { shownCategories, type Category, type CategoryGroup } from "./categories";
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
    text(row.summary),
    row.summary?.text ?? "",
    // The long help is never shown on the page, but a search still finds a row by its words.
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
  /** The host is a DEV build: DEV-only categories are searched too. */
  devBuild?: boolean;
};

/** Matching rows of every category, in navigation order; an empty query with changedOnly lists
 * every changed row. */
// Rows the page never lists: appearance.themeEdits is the theme pickers' "(custom)" themes.
const UNLISTED = new Set(["appearance.themeEdits"]);

export function filterRows({
  query,
  changedOnly = false,
  valueOf,
  isChanged,
  devBuild = false,
}: ListFilter): SearchGroup[] {
  const terms = queryTerms(query);
  const keep = (row: SchemaRow) =>
    !UNLISTED.has(row.key) &&
    (terms.length === 0 ? changedOnly : rowMatches(row, valueOf(row.key), terms)) &&
    (!changedOnly || (isChanged?.(row.key) ?? false));
  return shownCategories(devBuild)
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
