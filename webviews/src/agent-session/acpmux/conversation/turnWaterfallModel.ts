import type { Translate } from "../i18n";
import { formatDuration } from "./turns";

/// "840ms", "34s", "1m 12s": a Timeline time in the format of the turn's "Worked for" (turns.ts
/// `formatDuration`), so the popover and the line that opens it read the same (Leo, 2026-11-25:
/// "the 34s is weird to have on both"). Under a second it keeps its milliseconds.
export function spanTime(t: Translate, ms: number): string {
  if (ms < 1000) return t("duration.ms", { n: Math.round(ms) });
  return formatDuration(ms);
}
