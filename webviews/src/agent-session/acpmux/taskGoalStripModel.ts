/** How long ago a goal last changed, as the pane's language words a short relative time ("3 min.
 *  ago", "now"): the "Updated" line of the open goal and its hover card. */
export function goalUpdatedText(now: number, at: number, lang: string): string {
  const ago = Math.max(0, now - at);
  const format = new Intl.RelativeTimeFormat(lang, { style: "short", numeric: "auto" });
  if (ago < 60_000) return format.format(0, "second");
  if (ago < 3_600_000) return format.format(-Math.floor(ago / 60_000), "minute");
  if (ago < 48 * 3_600_000) return format.format(-Math.floor(ago / 3_600_000), "hour");
  return format.format(-Math.floor(ago / 86_400_000), "day");
}
