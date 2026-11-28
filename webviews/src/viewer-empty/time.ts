// Relative times for the recent lists ("5 minutes ago", "yesterday"), localized by Intl in the
// page's language, so no table string is needed.

const UNITS: Array<[Intl.RelativeTimeFormatUnit, number]> = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["week", 7 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
];

/** `then` relative to `now` (both milliseconds) in `language`; under a minute is "now". */
export function relativeTime(then: number, now: number, language: string): string {
  const format = new Intl.RelativeTimeFormat(language, { numeric: "auto", style: "short" });
  const seconds = Math.round((then - now) / 1000);
  const magnitude = Math.abs(seconds);
  for (const [unit, size] of UNITS) {
    if (magnitude >= size) return format.format(Math.trunc(seconds / size), unit);
  }
  return format.format(0, "second");
}
