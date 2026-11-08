// The parts of BrowserSearchEngine the keyword session needs synchronously: filling a query
// template, an engine's keyword and site, and the built-in engines (BrowserSearchEngine.swift,
// BrowserSearchEngine+Keyword.swift). Suggest requests stay native.
import { formatURL, parseURL } from "./url-display";
import type { OmnibarKeyword, SearchEngine } from "./types";

export const SEARCH_TERMS = "{searchTerms}";

const engine = (id: string, name: string, queryTemplate: string, suggestTemplate?: string): SearchEngine => ({
  id,
  name,
  queryTemplate,
  suggestTemplate: suggestTemplate ?? null,
});

export const SEARCH_ENGINES = {
  google: engine(
    "google",
    "Google",
    "https://www.google.com/search?q={searchTerms}",
    "https://suggestqueries.google.com/complete/search?client=firefox&q={searchTerms}",
  ),
  duckDuckGo: engine(
    "duckduckgo",
    "DuckDuckGo",
    "https://duckduckgo.com/?q={searchTerms}",
    "https://duckduckgo.com/ac/?q={searchTerms}&type=list",
  ),
  bing: engine(
    "bing",
    "Bing",
    "https://www.bing.com/search?q={searchTerms}",
    "https://api.bing.com/osjson.aspx?query={searchTerms}",
  ),
  brave: engine(
    "brave",
    "Brave",
    "https://search.brave.com/search?q={searchTerms}",
    "https://search.brave.com/api/suggest?q={searchTerms}",
  ),
  kagi: engine(
    "kagi",
    "Kagi",
    "https://kagi.com/search?q={searchTerms}",
    "https://kagi.com/api/autosuggest?q={searchTerms}",
  ),
  youtube: engine("youtube", "YouTube", "https://www.youtube.com/results?search_query={searchTerms}"),
  wikipedia: engine("wikipedia", "Wikipedia", "https://en.wikipedia.org/w/index.php?search={searchTerms}"),
  github: engine("github", "GitHub", "https://github.com/search?q={searchTerms}"),
} as const;

export const BUILT_IN_ENGINES: readonly SearchEngine[] = [
  SEARCH_ENGINES.google,
  SEARCH_ENGINES.duckDuckGo,
  SEARCH_ENGINES.bing,
  SEARCH_ENGINES.brave,
  SEARCH_ENGINES.kagi,
];

/** Sites with a search engine besides the built-in engines. */
export const SITE_SEARCHES: readonly SearchEngine[] = [
  SEARCH_ENGINES.youtube,
  SEARCH_ENGINES.wikipedia,
  SEARCH_ENGINES.github,
];

const KEYWORD_OVERRIDES: Record<string, string> = { wikipedia: "wikipedia.org" };

/** RFC 3986 unreserved characters stay; everything else is escaped. */
function encodeQueryValue(text: string): string {
  return encodeURIComponent(text).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

/** The search results URL for `query`, or null for an empty query or a template without the placeholder. */
export function searchURL(engine: SearchEngine, query: string): string | null {
  const trimmed = query.trim();
  if (!trimmed || !engine.queryTemplate.includes(SEARCH_TERMS)) return null;
  return engine.queryTemplate.replaceAll(SEARCH_TERMS, encodeQueryValue(trimmed));
}

/** What the user types to search with `engine`: its search host without `www.`. */
export function engineKeyword(engine: SearchEngine): string | null {
  const override = KEYWORD_OVERRIDES[engine.id];
  if (override) return override;
  const host = parseURL(engine.queryTemplate.replaceAll(SEARCH_TERMS, "x"))?.host?.toLowerCase();
  if (!host) return null;
  return host.startsWith("www.") ? host.slice(4) : host;
}

/** The engine's site (Enter with no text in its keyword session). */
export function engineSiteURL(engine: SearchEngine): string | null {
  const parts = parseURL(engine.queryTemplate.replaceAll(SEARCH_TERMS, "x"));
  if (!parts) return null;
  return formatURL({ ...parts, path: "/", query: null, fragment: null });
}

/** A search engine's keyword: Enter searches with `engine`. */
export function keywordForEngine(engine: SearchEngine): OmnibarKeyword {
  return { extensionID: "", keyword: engineKeyword(engine) ?? "", name: engine.name, searchEngine: engine };
}

/** The keywords of `defaultEngine` (first), the built-in engines and the site searches, one per keyword. */
export function searchEngineKeywords(defaultEngine: SearchEngine): OmnibarKeyword[] {
  const seen = new Set<string>();
  const keywords: OmnibarKeyword[] = [];
  for (const candidate of [defaultEngine, ...BUILT_IN_ENGINES, ...SITE_SEARCHES]) {
    const keyword = engineKeyword(candidate);
    if (keyword == null || seen.has(keyword)) continue;
    seen.add(keyword);
    keywords.push(keywordForEngine(candidate));
  }
  return keywords;
}
