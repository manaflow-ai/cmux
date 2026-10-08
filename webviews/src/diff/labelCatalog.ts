import english from "../pages/diff/generated/locales/en.json";
import { createStrings, type Strings, type StringTable } from "../pages/shared/i18n";

export type DiffLocaleLoaders = Record<string, () => Promise<{ default: Record<string, string> }>>;

/** One page's loaded labels. English is eager; translations load only when selected. */
export class DiffLabelCatalog {
  private readonly tables: StringTable;
  private readonly pending = new Map<string, Promise<void>>();
  private readonly loaded = new Set(["en"]);

  constructor(private readonly loaders: DiffLocaleLoaders) {
    // Retain the complete locale list for the shared document languagechange handler.
    this.tables = Object.fromEntries(Object.keys(loaders).map((locale) => [locale, {}]));
    this.tables.en = english;
  }

  load(language: string): Promise<void> {
    if (this.loaded.has(language)) return Promise.resolve();
    const loader = this.loaders[language];
    if (!loader) return Promise.reject(new Error(`Unsupported diff locale: ${language}`));
    const existing = this.pending.get(language);
    if (existing) return existing;
    const promise = loader().then(
      ({ default: table }) => {
        this.tables[language] = table;
        this.loaded.add(language);
        this.pending.delete(language);
      },
      (error: unknown) => {
        this.pending.delete(language);
        throw error;
      },
    );
    this.pending.set(language, promise);
    return promise;
  }

  strings(language: string): Strings {
    if (!this.loaded.has(language)) throw new Error(`Diff locale must load before rendering: ${language}`);
    return createStrings(this.tables, [language]);
  }
}
