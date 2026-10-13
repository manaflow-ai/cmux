// Strings come from pages/diff/Localizable.xcstrings through scripts/pages/gen-strings.mjs.
import english from "./pages/diff/generated/locales/en.json";
import { diffLocaleLoaders } from "./pages/diff/generated/localeLoaders";
import { resolveLanguage } from "./pages/shared/i18n";
import { DiffLabelCatalog } from "./diff/labelCatalog";

const catalog = new DiffLabelCatalog(diffLocaleLoaders);
const availableLanguages = ["en", ...Object.keys(diffLocaleLoaders)];

type CatalogKey = keyof typeof english;
/** Distributes over the catalog's keys: the table also holds the changes view's git strings. */
type ViewerKey<K> = K extends `diffViewer.${infer Key}` ? Key : never;
export type DiffViewerLabelKey = ViewerKey<CatalogKey>;
export type DiffViewerLabelResolver = (key: DiffViewerLabelKey) => string;
export type DiffViewerLanguage = string;

/** The first supported app locale, using the same resolution as every page. */
export function diffViewerLanguage(
  languages: readonly string[] = globalThis.navigator?.languages ?? [],
): DiffViewerLanguage {
  return resolveLanguage(languages, availableLanguages);
}

/** Unprefixed labels for protocol callers that still supply an override table. */
export function diffViewerLabelsFor(language: DiffViewerLanguage): Record<DiffViewerLabelKey, string> {
  const strings = catalog.strings(language);
  return Object.fromEntries(
    viewerKeys(Object.keys(english)).map((key) => [key.slice("diffViewer.".length), strings.t(key)]),
  ) as Record<DiffViewerLabelKey, string>;
}

/** The viewer's own keys; the table also carries the changes view's git strings (diff-viewer/git.ts). */
const viewerKeys = (keys: string[]) => keys.filter((key) => key.startsWith("diffViewer."));

export const DEFAULT_DIFF_VIEWER_LABELS = Object.fromEntries(
  viewerKeys(Object.keys(english)).map((key) => [key.slice("diffViewer.".length), english[key as CatalogKey]]),
) as Record<DiffViewerLabelKey, string>;

/** The loaded table's changes view strings in `language` and English, for the reused Stage, Commit and Push. */
export function diffGitStrings(language: DiffViewerLanguage): Record<string, Record<string, string>> {
  const pick = (table: Record<string, string>) =>
    Object.fromEntries(Object.entries(table).filter(([key]) => !key.startsWith("diffViewer.")));
  return { en: pick(english), [language]: pick(catalog.table(language)) };
}
/** Resolves before any diff UI is rendered; a failed locale fetch never paints English first. */
export function loadDiffViewerLabels(language: DiffViewerLanguage = diffViewerLanguage()): Promise<void> {
  return catalog.load(language);
}

type LabelResolverOptions = {
  assertMissing?: boolean;
  /** Overrides the language read from navigator.languages (tests). */
  language?: DiffViewerLanguage;
};

export function shouldAssertMissingLabels(): boolean {
  return Boolean(import.meta.env?.DEV);
}

export function createDiffViewerLabelResolver(
  labels: Record<string, string> | undefined,
  options: LabelResolverOptions = {},
): DiffViewerLabelResolver {
  const strings = catalog.strings(options.language ?? diffViewerLanguage());
  const missingKeys = new Set<DiffViewerLabelKey>();
  return (key) => {
    // Classic hosts may customize labels; the page host does not need to send any.
    const override = labels?.[key];
    if (typeof override === "string" && override.trim()) return override;
    const catalogKey = `diffViewer.${key}`;
    const value = strings.t(catalogKey);
    if (value === catalogKey && options.assertMissing && !missingKeys.has(key)) {
      missingKeys.add(key);
      throw new Error(`Missing cmux diff viewer label: ${key}`);
    }
    return value;
  };
}
