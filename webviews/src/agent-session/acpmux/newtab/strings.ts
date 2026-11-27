// The new tab screen's strings, in the pane's language (`usePaneLanguage`, which follows the app's
// preferred localizations). They are the `newTab.` keys of the pane's table (acpmux/i18n.ts,
// Localizable.xcstrings). Components read them through `useNt()` so a language change re-renders
// them; `translateNewTab` is for code outside render.
import { useSyncExternalStore } from "react";
import {
  currentLanguage,
  currentTranslator,
  subscribeLanguage,
  translateKey,
  type CatalogKey,
  type PaneLanguage,
  type Translate,
} from "../i18n";

export type NewTabStringKey = CatalogKey extends infer K ? (K extends `newTab.${infer Name}` ? Name : never) : never;

export type NewTabTranslate = (key: NewTabStringKey, values?: Record<string, string>) => string;

/** A new tab string, with `{name}` placeholders filled. Outside render only; components use `useNt()`. */
export function translateNewTab(
  key: NewTabStringKey,
  values: Record<string, string> = {},
  lang: PaneLanguage = currentLanguage(),
): string {
  return translateKey(`newTab.${key}` as CatalogKey, values, lang);
}

const translators = new Map<Translate, NewTabTranslate>();

/** The new tab translator for the pane's language now: a new one whenever the pane's translator is
 *  (a language change, or tables that arrived late, i18n.ts `recoverStrings`). */
function currentNewTabTranslator(): NewTabTranslate {
  const pane = currentTranslator();
  let translator = translators.get(pane);
  if (!translator) {
    const lang = currentLanguage();
    translator = (key, values) => translateNewTab(key, values, lang);
    translators.clear();
    translators.set(pane, translator);
  }
  return translator;
}

/** The new tab translator for the pane's current language; re-renders the caller when it changes. */
export function useNt(): NewTabTranslate {
  return useSyncExternalStore(subscribeLanguage, currentNewTabTranslator, currentNewTabTranslator);
}
