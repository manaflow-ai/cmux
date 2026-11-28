// Owns the language of each diff item: resolving it once per item, re-resolving after the
// language registry changes, and the languages a highlighter must preload.
import { resolveDiffFileLanguage, resolveDiffPreloadLanguages } from "../diff-language";
import { fileName, type DiffItem } from "../diff-stream";

/// Sets `fileDiff.lang` to the detected language. The language the parser chose and the
/// worker cache key are kept beside it, so a later language change (the host pushed new user
/// languages) detects from the same input and never reads a cached render of the old language.
export function resolveDiffItemLanguage(item: DiffItem): void {
  const diff = item.fileDiff;
  if (diff == null) {
    return;
  }
  if (!("cmuxParsedLanguage" in diff)) {
    diff.cmuxParsedLanguage = diff.lang;
    diff.cmuxBaseCacheKey = diff.cacheKey;
  }
  const lang = resolveDiffFileLanguage(fileName(diff, ""), diff.cmuxParsedLanguage, diff);
  diff.lang = lang;
  if (typeof diff.cmuxBaseCacheKey === "string") {
    diff.cacheKey = `${diff.cmuxBaseCacheKey}:${lang}`;
  }
}

/// The items whose language changed under the current language registry, as new objects.
export function relanguagedItems(items: DiffItem[]): DiffItem[] {
  return items.map((item) => {
    const diff = item.fileDiff;
    if (diff == null) {
      return item;
    }
    const next = { ...item, fileDiff: { ...diff } };
    resolveDiffItemLanguage(next);
    return next.fileDiff.lang === diff.lang ? item : { ...next, version: (item.version ?? 0) + 1 };
  });
}

export function diffItemPreloadLanguages(item: DiffItem): string[] {
  const diff = item.fileDiff;
  if (diff == null) {
    return [];
  }
  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff);
}

export function mergeLanguages(current: string[], next: string[]): string[] {
  const languages = new Set(current);
  for (const language of next) {
    if (language.trim().length > 0) {
      languages.add(language);
    }
  }
  return Array.from(languages);
}
