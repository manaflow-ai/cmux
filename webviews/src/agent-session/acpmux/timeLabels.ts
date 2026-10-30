import { currentLanguage, type Translate, translate } from "./i18n";

const WEEK_MINUTES = 7 * 24 * 60;

/** Compact relative time for recent activity, then a localized date once age is unambiguous. */
export function ageWithDate(
  updatedAt: number | undefined,
  now = Date.now(),
  relative: (minutes: number, t: Translate) => string,
  t: Translate = translate,
): string {
  if (!updatedAt) return "";
  const minutes = Math.max(0, Math.floor((now - updatedAt) / 60_000));
  if (minutes >= WEEK_MINUTES) {
    const language = currentLanguage() || globalThis.navigator?.language || "en";
    return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(new Date(updatedAt));
  }
  return relative(minutes, t);
}
