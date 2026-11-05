// How an opened run's background commands stand while any still runs, as Claude Code desktop notes
// it among a run's rows: "1 background command completed, 1 running", or "1 background command
// completed, 1 failed, 1 running" with "1 failed" in the error tone (Leo, 2026-11-03: "claude code
// desktop's summarization of tool calls/parsing of them seem kinda good?"). One quiet line on the
// rows' grid at the end of the opened group's steps (ToolGroupRow.tsx); once none runs it goes, and
// the group's head counts what finished ("Finished 2 background tasks, ran 5 commands").
import { Fragment } from "react";
import { useT, type Translate } from "../i18n";
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

export function BackgroundStatusLine({ counts }: { counts: BackgroundCounts }) {
  const t = useT();
  const parts = backgroundStatusParts(t, counts);
  return (
    <output className="cv-bgstatus" data-find-skip>
      {/* One line box: as flex items, the separator's text would lose its space ("completed,1 failed"). */}
      <span className="cv-bgstatus__text">
        {parts.map((part, at) => (
          <Fragment key={part.text}>
            {at > 0 && t("toolRun.separator")}
            <span className={part.failed ? "cv-tool__failed" : undefined}>{part.text}</span>
          </Fragment>
        ))}
      </span>
    </output>
  );
}
