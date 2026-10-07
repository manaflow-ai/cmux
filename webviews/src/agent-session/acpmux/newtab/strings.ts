// The new tab screen's strings, in the pane's language (`usePaneLanguage`, which follows the app's
// preferred localizations). They are the `newTab.` keys of the pane's table (acpmux/i18n.ts,
// Localizable.xcstrings). Components read them through `useNt()` so a language change re-renders
// them; `translateNewTab` is for code outside render.
import { currentLanguage, translateKey, type PaneLanguage, usePaneLanguage } from "../i18n";

type CatalogKey = keyof (typeof import("../generated/strings.json"))["en"];
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

const translators = new Map<PaneLanguage, NewTabTranslate>();

/** The new tab translator for the pane's current language; re-renders the caller when it changes. */
export function useNt(): NewTabTranslate {
  const lang = usePaneLanguage();
  let translator = translators.get(lang);
  if (!translator) {
    translator = (key, values) => translateNewTab(key, values, lang);
    translators.set(lang, translator);
  }
  return translator;
}
