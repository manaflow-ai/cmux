import {
  localizedSearchTokenAliases,
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
  return String(value || "").trim().toLowerCase();
}

export const searchTokenAliases = new Map(localizedEntries(localizedSearchTokenAliases));

export const settingsCategorySearchAliases = new Map(localizedEntries(localizedSettingsCategorySearchAliases));

export function uniqueSearchTokens(tokens) {
  return [...new Set(tokens.filter(Boolean))];
}

export function settingsSearchTokens(value) {
  return normalizeSettingsQuery(value).split(/\s+/).filter(Boolean).map((token) => {
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
