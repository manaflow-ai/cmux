// Search across every category by title, summary, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere. "Show only
// changed" (P4) uses the same listing: the rows whose value differs from the default.
import { shownCategories, type Category, type CategoryGroup } from "./categories";
import { valueText } from "./format";
import type { SchemaRow } from "./schema";
import { locale, text } from "./strings";

export function queryTerms(query: string): string[] {
  return query.toLowerCase().split(/\s+/).filter(Boolean);
}

type SearchTextContext = { scope: string; revision: number };

type StaticSearchText = { locale: string; text: string };
type SearchText = StaticSearchText & { scope: string; revision: number; value: unknown };

// Schema rows are stable objects, so a weak cache keeps the expensive localization and value
// formatting work out of the per-keystroke path. The scope/revision/value tuple is part of the
// entry: a locale switch, a fresh owner revision, or an optimistic value update must never reuse
// text from an older settings snapshot.
const staticSearchTextCache = new WeakMap<SchemaRow, StaticSearchText>();
const searchTextCache = new WeakMap<SchemaRow, SearchText>();

function staticSearchableText(row: SchemaRow): StaticSearchText {
  const activeLocale = locale();
  const cached = staticSearchTextCache.get(row);
  if (cached?.locale === activeLocale) return cached;
  const entry = {
    locale: activeLocale,
    text: [
      text(row.title),
      row.title.text,
      text(row.summary),
      row.summary?.text ?? "",
      // The long help is never shown on the page, but a search still finds a row by its words.
      text(row.help),
      row.help?.text ?? "",
      row.key,
      ...row.keywords,
    ]
      .join("\n")
      .toLowerCase(),
  };
  staticSearchTextCache.set(row, entry);
  return entry;
}

function searchableText(row: SchemaRow, value: unknown, context: SearchTextContext): string {
  const activeLocale = locale();
  const staticText = staticSearchableText(row);
  const cached = searchTextCache.get(row);
  if (
    cached &&
    cached.locale === activeLocale &&
    cached.scope === context.scope &&
    cached.revision === context.revision &&
    Object.is(cached.value, value)
  )
    return cached.text;
  const entry = {
    ...staticText,
    scope: context.scope,
    revision: context.revision,
    value,
    text: `${staticText.text}\n${valueText(row, value).toLowerCase()}`,
  };
  searchTextCache.set(row, entry);
  return entry.text;
}

export function rowMatches(
  row: SchemaRow,
  value: unknown,
  terms: string[],
  context: SearchTextContext = { scope: "user", revision: 0 },
): boolean {
  if (terms.length === 0) return false;
  const haystack = searchableText(row, value, context);
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
  /** Settings scope and owner revision used to invalidate the searchable text cache. */
  scope?: string;
  revision?: number;
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
  scope = "user",
  revision = 0,
}: ListFilter): SearchGroup[] {
  const terms = queryTerms(query);
  const keep = (row: SchemaRow) =>
    !UNLISTED.has(row.key) &&
    (terms.length === 0 ? changedOnly : rowMatches(row, valueOf(row.key), terms, { scope, revision })) &&
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
