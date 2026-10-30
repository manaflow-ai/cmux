// The agent pane's strings, in every language the app ships. They come from
// acpmux/Localizable.xcstrings through the pages' generator (scripts/pages/gen-strings.mjs writes
// generated/strings.json); no string lives only in TypeScript. The shipped pane does not bundle
// that table: build-agent-pane-web.sh splits it into locales/<code>.js beside index.html, and the
// page's <head> loads English plus the app's language synchronously, before the pane's module
// runs, into `window.__cmuxPaneStrings`. Tests (test/preload.ts) and the dev server (dev.tsx)
// install the whole table there. The language is the first of the app's languages
// (`navigator.languages`, which follows the app's preferred localizations) that is loaded.
//
// The language is a reactive value: a small store that follows the page window's
// `languagechange` (and `setPaneLanguage`). Components read strings through `useT()`, so a language change
// re-renders them under either React Compiler; a module-level function read during render
// would look constant to the compiler and keep memoized strings stale. `translate` is for
// code outside render (event handlers, clients), where the current language is read once.
import { useSyncExternalStore } from "react";
import { resolveLanguage, setDocumentLanguage } from "../../pages/shared/i18n";

type Catalog = typeof import("./generated/strings.json");
/** A plural string's text per CLDR category is `key#<category>` in the table (gen-strings.mjs). */
type PluralBase<Key> = Key extends `${infer Base}#${string}` ? Base : Key;
/** A catalog string's key; a plural string's is its base, without `#<category>`. */
export type CatalogKey = PluralBase<keyof Catalog["en"]>;
/** A pane string's key (the new tab screen's keys are newtab/strings.ts's, under `newTab.`). */
export type StringKey = Exclude<CatalogKey, `newTab.${string}`>;
type Table = Partial<Record<CatalogKey, string>>;

declare global {
  // eslint-disable-next-line no-var
  var __cmuxPaneStrings: Record<string, Table> | undefined;
}

const tables = (): Record<string, Table> => globalThis.__cmuxPaneStrings ?? {};

/** An Apple localization code the pane has strings for (`en`, `ja`, `pt-BR`, `zh-Hant`, ...). */
export type PaneLanguage = string;
export type StringValues = Record<string, string | number>;
/** A pane string in one language, with `{name}` placeholders filled. */
export type Translate = (key: StringKey, values?: StringValues) => string;

/** The pane's language: the first of the app's languages the pane has strings for. */
export function paneLanguage(languages: readonly string[] = globalThis.navigator?.languages ?? []): PaneLanguage {
  return resolveLanguage(languages, Object.keys(tables()));
}

let active: PaneLanguage = paneLanguage();
setDocumentLanguage(active);
const listeners = new Set<() => void>();

// The window whose `languagechange` the store follows. It is attached on first use (a read, a
// subscribe or a switch), not when the module loads: bun shares one module cache across test
// files, so this module may first load before any window exists, and a later file installs its
// own. Each use compares one reference; when the global window is a different one, the listener
// moves to it, so the old window keeps none.
let followed: typeof globalThis.window | undefined;
const followLanguageChange = () => setPaneLanguage(paneLanguage());
function followWindow(): void {
  const view = globalThis.window as typeof globalThis.window | undefined;
  if (view === followed) return;
  followed?.removeEventListener("languagechange", followLanguageChange);
  followed = view;
  followed?.addEventListener("languagechange", followLanguageChange);
}
followWindow();

/** The language the pane renders in now. */
export function currentLanguage(): PaneLanguage {
  followWindow();
  return active;
}

/** Switches the pane's language; every component that reads strings through `useT()` re-renders. */
export function setPaneLanguage(next: PaneLanguage): void {
  followWindow();
  setDocumentLanguage(next);
  if (next === active) return;
  active = next;
  for (const listener of listeners) listener();
}

/** Calls `listener` after each language change; returns the unsubscribe function. */
export function subscribeLanguage(listener: () => void): () => void {
  followWindow();
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const pluralRules = new Map<PaneLanguage, Intl.PluralRules>();
/** `key`, or for a plural string the form `lang`'s plural rules pick for `values.n`. */
function formKey(key: string, values: StringValues, lang: PaneLanguage): string {
  if (!(`${key}#other` in (tables().en ?? {}))) return key;
  let rules = pluralRules.get(lang);
  if (!rules) {
    rules = new Intl.PluralRules(lang);
    pluralRules.set(lang, rules);
  }
  return `${key}#${rules.select(Number(values.n ?? 0))}`;
}

/** A catalog string in `lang` (English when it has none), with `{name}` placeholders filled. A
 *  plural string takes the form `lang`'s plural rules pick for `{n}`. */
export function translateKey(key: CatalogKey, values: StringValues, lang: PaneLanguage): string {
  const table = tables()[lang] as Record<string, string> | undefined;
  const english = tables().en as Record<string, string> | undefined;
  const text = table?.[formKey(key, values, lang)] ?? english?.[formKey(key, values, "en")] ?? key;
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole));
}

/** A pane string, with `{name}` placeholders filled. Outside render only; components use `useT()`. */
export function translate(key: StringKey, values: StringValues = {}, lang: PaneLanguage = currentLanguage()): string {
  return translateKey(key, values, lang);
}

// One translator per language, so `useT()` returns a value that changes exactly when the
// language does (a memoized string depends on it, and stays cached otherwise).
const translators = new Map<PaneLanguage, Translate>();

/** The translator for `lang`, for code that already holds a language. */
export function translatorFor(lang: PaneLanguage): Translate {
  let translator = translators.get(lang);
  if (!translator) {
    translator = (key, values) => translate(key, values, lang);
    translators.set(lang, translator);
  }
  return translator;
}

/** The pane's language as React state. */
export function usePaneLanguage(): PaneLanguage {
  return useSyncExternalStore(subscribeLanguage, currentLanguage, currentLanguage);
}

/** The translator for the pane's current language; re-renders the caller when it changes. */
export function useT(): Translate {
  return translatorFor(usePaneLanguage());
}

/** Every loaded language's table, for tests that keep the tables complete. */
export const STRING_TABLES: Record<string, Record<string, string>> = tables() as Record<string, Record<string, string>>;
