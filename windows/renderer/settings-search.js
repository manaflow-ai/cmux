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

export function normalizeSettingsQuery(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

export const searchTokenAliases = new Map(localizedEntries(localizedSearchTokenAliases));

export const searchStopWords = new Set(localizedEntries(localizedSearchStopWords));

export const settingsCategorySearchAliases = new Map(localizedEntries(localizedSettingsCategorySearchAliases));

export function uniqueSearchTokens(tokens) {
  return [...new Set(tokens.filter(Boolean))];
}

export function settingsSearchTokens(value) {
  return normalizeSettingsQuery(value).split(/\s+/).filter((token) => token && !searchStopWords.has(token)).map((token) => {
    const aliases = searchTokenAliases.get(token) || [];
    return uniqueSearchTokens([token, ...aliases]);
  });
}

export function settingsSearchMatches(searchText, tokens) {
  return settingsSearchMatchesNormalized(normalizeSettingsQuery(searchText), tokens);
}

export function settingsSearchMatchesNormalized(haystack, tokens) {
  if (!tokens.length) return true;
  return tokens.every((group) => group.some((token) => haystack.includes(token)));
}
