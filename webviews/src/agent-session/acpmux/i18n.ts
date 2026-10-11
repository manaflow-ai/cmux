// The agent pane's strings, in every language the app ships. They come from
// acpmux/Localizable.xcstrings through the pages' generator (scripts/pages/gen-strings.mjs writes
// generated/strings.json); no string lives only in TypeScript. The shipped pane does not bundle
// that table: build-agent-pane-web.sh splits it into locales/<code>.js beside index.html, and the
// page's <head> loads English plus the app's language synchronously, before the pane's module
// runs, into `window.__cmuxPaneStrings`. Tests (test/preload.ts) and the dev server (dev.tsx)
// install the whole table there. The language is the first of the app's languages
// (`navigator.languages`, which follows the app's preferred localizations) that is loaded.
//
// The language is a reactive value: a small store that follows `languagechange` (and
// `setPaneLanguage`). Components read strings through `useT()`, so a language change
// re-renders them under either React Compiler; a module-level function read during render
// would look constant to the compiler and keep memoized strings stale. `translate` is for
// code outside render (event handlers, clients), where the current language is read once.
import { useSyncExternalStore } from "react";
import { resolveLanguage, setDocumentLanguage } from "../../pages/shared/i18n";

type Catalog = typeof import("./generated/strings.json");
type CatalogKey = keyof Catalog["en"];
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

/** The language the pane renders in now. */
export function currentLanguage(): PaneLanguage {
  return active;
}

/** Switches the pane's language; every component that reads strings through `useT()` re-renders. */
export function setPaneLanguage(next: PaneLanguage): void {
  setDocumentLanguage(next);
  if (next === active) return;
  active = next;
  for (const listener of listeners) listener();
}

/** Calls `listener` after each language change; returns the unsubscribe function. */
export function subscribeLanguage(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

globalThis.window?.addEventListener("languagechange", () => setPaneLanguage(paneLanguage()));

/** A catalog string in `lang` (English when it has none), with `{name}` placeholders filled. */
export function translateKey(key: CatalogKey, values: StringValues, lang: PaneLanguage): string {
  const text = tables()[lang]?.[key] ?? tables().en?.[key] ?? key;
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole));
}

/** A pane string, with `{name}` placeholders filled. Outside render only; components use `useT()`. */
export function translate(key: StringKey, values: StringValues = {}, lang: PaneLanguage = active): string {
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
