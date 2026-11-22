// Localized strings, generated from the xcstrings catalogs by scripts/pages/gen-strings.mjs
// (generated/strings.json). The shipped page does not bundle that file (21 locales, most of the
// bundle): build-pages-web.sh splits it into locales/<locale>.js, and the page's <head> loads
// English plus the active locale before the app runs (window.__cmuxStrings). Tests and the dev
// server install the full table with installCatalog().
import type { LocalizedText } from "./schema";

type Catalog = Record<string, Record<string, string>>;

declare global {
  // eslint-disable-next-line no-var
  var __cmuxStrings: Catalog | undefined;
}

function catalogNow(): Catalog {
  return globalThis.__cmuxStrings ?? {};
}

/** Installs a catalog (tests and the dev server; the app loads it from locales/*.js). */
export function installCatalog(table: Catalog): void {
  globalThis.__cmuxStrings = { ...catalogNow(), ...table };
  current = catalogNow()[currentLocale] ?? catalogNow().en ?? {};
}

let current: Record<string, string> = catalogNow().en ?? {};
let currentLocale = "en";

/** The locales the page knows (the shipped build lists all 21 in its loader). */
export function locales(): string[] {
  return Object.keys(catalogNow());
}

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
  return candidates.find((candidate) => candidate in catalogNow()) ?? "en";
}

export function setLocale(tag: string | null | undefined): string {
  currentLocale = resolveLocale(tag);
  current = catalogNow()[currentLocale] ?? catalogNow().en ?? {};
  document.documentElement.lang = currentLocale;
  return currentLocale;
}

export function locale(): string {
  return currentLocale;
}

/** A page string by key; `%@` placeholders take `args` in order. */
export function t(key: string, ...args: Array<string | number>): string {
  let text = current[key] ?? catalogNow().en?.[key] ?? key;
  for (const arg of args) text = text.replace("%@", String(arg));
  return text;
}

/** A schema string: its catalog key when it has one, else the English text (proper names). */
export function text(value: LocalizedText | null | undefined): string {
  if (!value) return "";
  return (value.key && (current[value.key] ?? catalogNow().en?.[value.key])) || value.text;
}

/** The unit suffix of a `%@ unit` format ("pt", "s", "秒"). */
export function unitSuffix(key: string): string {
  return t(key, "").trim();
}
