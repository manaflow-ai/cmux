// Localized strings, generated from the xcstrings catalogs by
// scripts/settings/generate-strings.mjs (generated/strings.json). The page picks the
// locale the app reports in ready(), else navigator.language, else English.
import generated from "./generated/strings.json";
import type { LocalizedText } from "./schema";

type Catalog = Record<string, Record<string, string>>;

const catalog = generated as Catalog;

export const locales = Object.keys(catalog);

let current: Record<string, string> = catalog.en ?? {};
let currentLocale = "en";

/** Maps an app or browser language tag onto one of the catalog's locales. */
export function resolveLocale(tag: string | null | undefined): string {
  if (!tag) return "en";
  const parts = tag.replace(/_/g, "-").split("-");
  const language = parts[0]!.toLowerCase();
  const rest = parts.slice(1);
  const candidates: string[] = [tag];
  if (language === "zh") {
    const traditional = rest.some((part) => /^(hant|tw|hk|mo)$/i.test(part));
    candidates.push(traditional ? "zh-Hant" : "zh-Hans");
  }
  if (language === "pt") candidates.push("pt-BR");
  if (language === "no" || language === "nn") candidates.push("nb");
  candidates.push(language);
  return candidates.find((candidate) => candidate in catalog) ?? "en";
}

export function setLocale(tag: string | null | undefined): string {
  currentLocale = resolveLocale(tag);
  current = catalog[currentLocale] ?? catalog.en ?? {};
  document.documentElement.lang = currentLocale;
  return currentLocale;
}

export function locale(): string {
  return currentLocale;
}

/** A page string by key; `%@` placeholders take `args` in order. */
export function t(key: string, ...args: Array<string | number>): string {
  let text = current[key] ?? catalog.en?.[key] ?? key;
  for (const arg of args) text = text.replace("%@", String(arg));
  return text;
}

/** A schema string: its catalog key when it has one, else the English text (proper names). */
export function text(value: LocalizedText | null | undefined): string {
  if (!value) return "";
  return (value.key && (current[value.key] ?? catalog.en?.[value.key])) || value.text;
}

/** The unit suffix of a `%@ unit` format ("pt", "s", "秒"). */
export function unitSuffix(key: string): string {
  return t(key, "").trim();
}
