// Search across every category by title, summary, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere. "Show only
// changed" (P4) uses the same listing: the rows whose value differs from the default.
import { categoryById, shownCategories, type Category, type CategoryGroup } from "./categories";
import { CLOUD_MODELS_FOCUS } from "./router";
import { valueText } from "./format";
import type { DevicesJoinState } from "./ops";
import type { SchemaRow } from "./schema";
import { providerCatalog, providerName } from "./providerCatalog";
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

/**
 * A place on a page-only card that search finds beside the schema rows: Settings > Devices' join
 * consent switches (Screen sharing, Control, Your other Macs), which the host draws from its lists
 * (`devices_join`) while this Mac is joined to a team. Their text is the host's, already localized,
 * and `keywords` carry the page's language and English. Its key is the route's focus
 * (`#/settings/devices?focus=devices.join.control`, Swift `SettingsPageAnchor`).
 */
export type PagePlace = { key: string; category: string; title: string; help: string; keywords: string[] };

const JOIN_CONSENT = "devices.join.";

/** The focus key of a join consent switch (`devices.join.control`). */
export const joinConsentKey = (surface: string) => `${JOIN_CONSENT}${surface}`;

/** The category a page place's key opens on; null for a key that names none. */
export function placeCategory(key: string): string | null {
  return key.startsWith(JOIN_CONSENT) ? "devices" : null;
}

/** The join consent switches as search places; none while this Mac shows no join group. */
export function joinConsentPlaces(join: DevicesJoinState | null | undefined): PagePlace[] {
  return (join?.switches ?? []).map((item) => ({
    key: joinConsentKey(item.surface),
    category: "devices",
    title: item.title,
    help: item.help,
    keywords: item.keywords ?? [],
  }));
}

/** The places every term of `query` matches (title, help, keywords), in the host's order. */
export function filterPlaces(query: string, places: readonly PagePlace[]): PagePlace[] {
  const terms = queryTerms(query);
  if (terms.length === 0) return [];
  return places.filter((place) => {
    const haystack = [place.title, place.help, ...place.keywords].join("\n").toLowerCase();
    return terms.every((term) => haystack.includes(term));
  });
}

/** The place whose title or one of whose keywords is the whole query ("control", "remote control"):
 * Return opens it before any row that only contains the words. */
export function exactPlace(query: string, places: readonly PagePlace[]): PagePlace | null {
  const typed = queryTerms(query).join(" ");
  if (!typed) return null;
  return (
    places.find((place) => [place.title, ...place.keywords].some((word) => queryTerms(word).join(" ") === typed)) ??
    null
  );
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

export function exactSettingsDestination(
  query: string,
  devBuild: boolean,
): { section: string; card?: string } | undefined {
  const normalized = queryTerms(query).join(" ");
  if (!normalized) return undefined;
  const exact = (title: string) => queryTerms(title).join(" ") === normalized;
  const page = shownCategories(devBuild).find(({ title }) => exact(text(title)) || exact(title.text));
  if (page) return { section: page.id };
  const cloud = "settingsWindow.cloud.models.title";
  if (exact(t(cloud)) || exact(english(cloud))) return { section: "cloud", card: CLOUD_MODELS_FOCUS };
  const models = "settingsWindow.models.personal.title";
  if (exact(t(models)) || exact(english(models))) return { section: "models" };
}

export function modelSettingsMatches(query: string): { models: boolean; cloud: boolean } {
  const terms = queryTerms(query);
  if (!terms.length) return { models: false, cloud: false };
  const title = categoryById("models").title;
  const shared = [
    text(title),
    title.text,
    t("settingsWindow.models.personal.title"),
    t("settingsWindow.models.key.field"),
    t("settingsWindow.models.endpoint.title"),
    ...providerCatalog.filter((provider) => !provider.detectedOnly).map(providerName),
  ];
  const models = shared.join(" ").toLowerCase();
  const cloudTitle = t("settingsWindow.cloud.models.title");
  const cloud = [...shared, cloudTitle].join(" ").toLowerCase();
  const cloudTitleTerms = new Set(queryTerms(cloudTitle));
  const modelTerms = new Set(queryTerms(models));
  return {
    models: terms.every((term) => models.includes(term) && (!cloudTitleTerms.has(term) || modelTerms.has(term))),
    cloud: terms.every((term) => cloud.includes(term)),
  };
}
