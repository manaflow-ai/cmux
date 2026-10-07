// Generated from Resources/Localizable.xcstrings by scripts/pages/gen-strings.mjs.
import table from "./pages/diff/generated/strings.json";
import { createStrings, resolveLanguage } from "./pages/shared/i18n";

type CatalogKey = keyof typeof table.en;
export type DiffViewerLabelKey = CatalogKey extends `diffViewer.${infer Key}` ? Key : never;
export type DiffViewerLabelResolver = (key: DiffViewerLabelKey) => string;
export type DiffViewerLanguage = string;

/** The first supported app locale, using the same resolution as every page. */
export function diffViewerLanguage(
  languages: readonly string[] = globalThis.navigator?.languages ?? [],
): DiffViewerLanguage {
  return resolveLanguage(languages, Object.keys(table));
}

/** Unprefixed labels for protocol callers that still supply an override table. */
export function diffViewerLabelsFor(language: DiffViewerLanguage): Record<DiffViewerLabelKey, string> {
  const strings = (table as Record<string, Record<string, string>>)[language] ?? table.en;
  return Object.fromEntries(
    Object.entries(strings).map(([key, value]) => [key.slice("diffViewer.".length), value]),
  ) as Record<DiffViewerLabelKey, string>;
}

export const DEFAULT_DIFF_VIEWER_LABELS = diffViewerLabelsFor("en");
export const JAPANESE_DIFF_VIEWER_LABELS = diffViewerLabelsFor("ja");

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
  const strings = createStrings(table, options.language ? [options.language] : undefined);
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
