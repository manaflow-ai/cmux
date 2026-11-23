// Search across every category by title, summary, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere. "Show only
// changed" (P4) uses the same listing: the rows whose value differs from the default.
import { shownCategories, type Category, type CategoryGroup } from "./categories";
import { valueText } from "./format";
import type { SchemaRow } from "./schema";
import { english, locale, t, text } from "./strings";

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
  valueOf(key: string): unknown;
  /** The host is a DEV build: DEV-only categories are searched too. */
  devBuild?: boolean;
  /** Settings scope and owner revision used to invalidate the searchable text cache. */
  scope?: string;
  revision?: number;
};

/** Matching rows of every category, in navigation order; an empty query matches none. */
// Rows the page never lists: appearance.themeEdits is the theme pickers' "(custom)" themes and
// appearance.favoriteThemes their stars.
const UNLISTED = new Set(["appearance.themeEdits", "appearance.favoriteThemes"]);

export function filterRows({
  query,
  valueOf,
  devBuild = false,
  scope = "user",
  revision = 0,
}: ListFilter): SearchGroup[] {
  const terms = queryTerms(query);
  const keep = (row: SchemaRow) =>
    !UNLISTED.has(row.key) && terms.length > 0 && rowMatches(row, valueOf(row.key), terms, { scope, revision });
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

/**
 * Words that find a page by more than its title: its cards draw host data, not schema rows, so no
 * row would lead there. A catalog key whose value lists them, comma-separated (Leo 2026-11-22: "i
 * also couldnt find settings devices control"; the join prompt sends people to Settings > Devices
 * for its Screen sharing and Control switches).
 */
const PAGE_WORDS: Readonly<Record<string, string>> = {
  devices: "settingsPage.search.devicesWords",
};

/** Categories whose title or page words hold every term, in navigation order; an empty query matches none. */
export function filterPages({ query, devBuild = false }: Pick<ListFilter, "query" | "devBuild">): Category[] {
  const terms = queryTerms(query);
  if (terms.length === 0) return [];
  return shownCategories(devBuild).filter((category) => {
    const words = PAGE_WORDS[category.id];
    const haystack = [text(category.title), category.title.text, words ? t(words) : "", words ? english(words) : ""]
      .join("\n")
      .toLowerCase();
    return terms.every((term) => haystack.includes(term));
  });
}
