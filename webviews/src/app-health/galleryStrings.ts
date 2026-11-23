// l10n-allow-file: gallery support, not shipped UI.
// The app-health galleries' string table, read from this folder's own catalog. They used to borrow the
// server page's table, which holds no `appHealth.*` key, so every state drew its raw key
// ("appHealth.line.repairing") instead of its words.
import catalog from "./Localizable.xcstrings?raw";

type Catalog = {
  strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>;
};

/** `{<locale>: {<key>: <value>}}` (the shape `createStrings` takes), one entry per translated key. */
export function appHealthGalleryTable(): Record<string, Record<string, string>> {
  const table: Record<string, Record<string, string>> = {};
  for (const [key, entry] of Object.entries((JSON.parse(catalog) as Catalog).strings)) {
    for (const [locale, localized] of Object.entries(entry.localizations ?? {})) {
      const value = localized.stringUnit?.value;
      if (value !== undefined) (table[locale] ??= {})[key] = value;
    }
  }
  return table;
}
