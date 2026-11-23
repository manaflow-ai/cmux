// Localized strings, generated from the xcstrings catalogs by scripts/pages/gen-strings.mjs
// (generated/strings.json). The shipped page does not bundle that file (21 locales, most of the
// bundle): build-pages-web.sh splits it into locales/<locale>.js, and the page's <head> loads
// English plus the active locale before the app runs (window.__cmuxStrings). Tests and the dev
// server install the full table with installCatalog().
import type { LocalizedText } from "./schema";
import { appLanguages } from "../shared/appLanguage";
import { resolveLanguage } from "../shared/i18n";

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

/** Maps an app or browser language tag onto one of the catalog's locales (shared/i18n.ts). */
export function resolveLocale(tag: string | null | undefined): string {
  return tag ? resolveLanguage([tag], locales()) : "en";
}

export function setLocale(tag: string | null | undefined): string {
  currentLocale = resolveLocale(tag);
  current = catalogNow()[currentLocale] ?? catalogNow().en ?? {};
  document.documentElement.lang = currentLocale;
  return currentLocale;
}

/** The catalog locale for the app's language now (the Language setting's, else the browser's). */
export function appLocale(): string {
  return resolveLanguage(appLanguages(), locales());
}

/**
 * Follows the app's language: on each `languagechange` (shared/appLanguage.ts dispatches one once
 * the new locale's table is in) the page's locale becomes `appLocale()`, then `listener` runs.
 * Returns the unsubscribe function.
 */
export function subscribeLocale(listener: () => void): () => void {
  const view = globalThis.document?.defaultView ?? globalThis.window;
  const follow = () => {
    setLocale(appLocale());
    listener();
  };
  view?.addEventListener("languagechange", follow);
  return () => view?.removeEventListener("languagechange", follow);
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

/** A page string by key in English, whatever the page's language (search matches both). */
export function english(key: string): string {
  return catalogNow().en?.[key] ?? key;
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
