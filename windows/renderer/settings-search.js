import {
  localizedSearchTokenAliases,
  localizedSearchStopWords,
  localizedSettingsCategorySearchAliases
} from "./settings-search-locales.js";

function currentSearchLocale() {
  const documentLocale = typeof document !== "undefined" ? document.documentElement.lang : "";
  const navigatorLocale = typeof navigator !== "undefined" ? navigator.language : "";
  return String(documentLocale || navigatorLocale || "en").split("-")[0] || "en";
}

function localizedEntries(source) {
  const locale = currentSearchLocale();
  return source[locale] || source.en || [];
}

const settingsSearchCacheLimit = 2048;
const settingsSearchCacheMaxKeyLength = 4096;
const normalizedQueryCache = new Map();
const normalizedTokenCache = new Map();

function rememberSettingsSearchCache(cache, key, value) {
  if (key.length > settingsSearchCacheMaxKeyLength) return value;
  if (cache.size >= settingsSearchCacheLimit) {
    cache.delete(cache.keys().next().value);
  }
  cache.set(key, value);
  return value;
}

export function normalizeSettingsQuery(value) {
  const raw = String(value || "");
  const cached = normalizedQueryCache.get(raw);
  if (cached !== undefined) return cached;
  return rememberSettingsSearchCache(normalizedQueryCache, raw, raw
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " "));
}

export const searchTokenAliases = new Map(localizedEntries(localizedSearchTokenAliases));

export const searchStopWords = new Set(localizedEntries(localizedSearchStopWords));

export const settingsCategorySearchAliases = new Map(localizedEntries(localizedSettingsCategorySearchAliases));

export function uniqueSearchTokens(tokens) {
  return [...new Set(tokens.filter(Boolean))];
}

export function settingsSearchTokens(value) {
  return settingsSearchTokensNormalized(normalizeSettingsQuery(value));
}

export function settingsSearchTokensNormalized(value) {
  const normalized = String(value || "").trim();
  if (!normalized) return [];
  const cached = normalizedTokenCache.get(normalized);
  if (cached) return cached;
  const tokens = normalized.split(/\s+/).filter((token) => !searchStopWords.has(token)).map((token) => {
    const aliases = searchTokenAliases.get(token) || [];
    return uniqueSearchTokens([token, ...aliases]);
  });
  return rememberSettingsSearchCache(normalizedTokenCache, normalized, tokens);
}

export function settingsSearchMatches(searchText, tokens) {
  return settingsSearchMatchesNormalized(normalizeSettingsQuery(searchText), tokens);
}

export function settingsSearchMatchesNormalized(haystack, tokens) {
  if (!tokens.length) return true;
  return tokens.every((group) => group.some((token) => haystack.includes(token)));
}
