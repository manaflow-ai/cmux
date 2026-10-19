// The markdown page's string table, split by locale (scripts/pages/gen-strings.mjs, `splitLocales`):
// English is the eager fallback, and only the translation the app's language picks is fetched, so the
// page's first load stays inside its eager JS budget (scripts/check-webviews-diff-budget.mjs).
import { resolveLanguage, type StringTable } from "../shared/i18n";
import english from "./generated/locales/en.json";
import { localeLoaders } from "./generated/localeLoaders";

const loaders: Record<string, () => Promise<{ default: Record<string, string> }>> = localeLoaders;

/** The locales loaded so far. The gallery adds its pseudo-locales here before the page boots. */
export const markdownTable: StringTable = { en: english };

/** The table with the translation `tags` pick loaded: at once when it is already here, else after one fetch. */
export function markdownTableFor(tags: readonly string[]): StringTable | Promise<StringTable> {
  const language = resolveLanguage(tags, [...Object.keys(markdownTable), ...Object.keys(loaders)]);
  const load = loaders[language];
  if (markdownTable[language] || !load) return markdownTable;
  return load().then(
    (module) => {
      markdownTable[language] = module.default;
      return markdownTable;
    },
    // A translation that fails to load leaves the page in English rather than blank.
    () => markdownTable,
  );
}
