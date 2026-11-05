import { type Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";

export type BackgroundCounts = { completed: number; failed: number; running: number };

/// The background commands among `items` by how they stand, or undefined when none still runs.
export function backgroundCounts(items: readonly AcpmuxActivity[]): BackgroundCounts | undefined {
  const counts: BackgroundCounts = { completed: 0, failed: 0, running: 0 };
  for (const item of items) {
    const state = item.tool?.background?.state;
    if (state === "running") counts.running += 1;
    else if (state === "completed") counts.completed += 1;
    else if (state === "failed") counts.failed += 1;
  }
  return counts.running > 0 ? counts : undefined;
}

/// The line's parts in Claude's order (completed, failed, running), the first naming the commands.
export function backgroundStatusParts(t: Translate, counts: BackgroundCounts): { text: string; failed: boolean }[] {
  const parts: { text: string; failed: boolean }[] = [];
  const states = [
    ["completed", counts.completed],
    ["failed", counts.failed],
    ["running", counts.running],
  ] as const;
  for (const [state, n] of states) {
    if (n === 0) continue;
    const first = parts.length === 0;
    const text = first
      ? n === 1
        ? t(`bgStatus.${state}.one`, { n })
        : t(`bgStatus.${state}.other`, { n })
      : state === "failed"
        ? t("tools.failedCount", { n })
        : t(`bgStatus.${state}Count`, { n });
    parts.push({ text, failed: state === "failed" });
  }
  return parts;
}
