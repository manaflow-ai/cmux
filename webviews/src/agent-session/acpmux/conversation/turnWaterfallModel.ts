import type { Translate } from "../i18n";

/// "840ms", "4.2s", "2m 5s", as a call row's own time (toolGroups.ts toolDuration).
export function spanTime(t: Translate, ms: number): string {
  if (ms < 1000) return t("duration.ms", { n: Math.round(ms) });
  if (ms < 60_000) return t("duration.s", { n: (ms / 1000).toFixed(1) });
  const seconds = Math.round(ms / 1000);
  return t("duration.m", { m: Math.floor(seconds / 60), s: seconds % 60 });
}
