import { currentLanguage, type Translate, translate } from "./i18n";
import { intl } from "../../ui/intl";

const WEEK_MINUTES = 7 * 24 * 60;

/** Compact relative time for recent activity, then a localized date once age is unambiguous.
 *  `relative` gets whole minutes (floored) and the elapsed milliseconds, for a caller that rounds. */
export function ageWithDate(
  updatedAt: number | undefined,
  now = Date.now(),
  relative: (minutes: number, t: Translate, elapsedMs: number) => string,
  t: Translate = translate,
): string {
  if (!updatedAt) return "";
  const elapsedMs = Math.max(0, now - updatedAt);
  const minutes = Math.floor(elapsedMs / 60_000);
  if (minutes >= WEEK_MINUTES) {
    const language = currentLanguage() || globalThis.navigator?.language || "en";
    return intl.DateTimeFormat(language, { dateStyle: "medium" }).format(new Date(updatedAt));
  }
  return relative(minutes, t, elapsedMs);
}
