/** When a loop next runs, as the pane's language words a short relative time ("in 4 min."); none
 *  once that time has passed (the run is due or running). */
export function loopNextText(now: number, at: number, lang: string): string | undefined {
  const left = at - now;
  if (left <= 0) return undefined;
  const format = new Intl.RelativeTimeFormat(lang, { style: "short", numeric: "always" });
  if (left < 60_000) return format.format(Math.ceil(left / 1_000), "second");
  if (left < 3_600_000) return format.format(Math.max(1, Math.round(left / 60_000)), "minute");
  if (left < 48 * 3_600_000) return format.format(Math.round(left / 3_600_000), "hour");
  return format.format(Math.round(left / 86_400_000), "day");
}
