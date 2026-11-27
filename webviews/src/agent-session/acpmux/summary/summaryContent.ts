// Whether the chat's summary has anything to show (the summary column or popover opens only then).
import type { AcpmuxRow } from "../model";
import { chatGallery } from "./chatGallery";

/// Whether one row puts something in the summary: subagents, a background task, or a tool call
/// the summary lists (an edit, a fetch, a thought, a wakeup or cron job, a background shell, a
/// pull request command).
function rowShowsInSummary(row: AcpmuxRow): boolean {
  if (row.subagents?.length || row.backgroundTask) return true;
  if (row.kind !== "activity") return false;
  return (
    row.items?.some((item) => {
      const tool = item.tool;
      if (!tool) return false;
      if (tool.diffs?.length || tool.kind === "fetch" || tool.kind === "think" || tool.background) return true;
      // Wakeups and cron jobs arrive as kind "other", named by their title (the summary's
      // scheduled() list reads them the same way).
      if (/^(?:ScheduleWakeup|CronCreate)\b/.test(tool.title) && tool.status !== "failed") return true;
      if (tool.kind !== "execute") return false;
      // Claude's raw input arrives as JSON (`"run_in_background":true`).
      const command = `${tool.command ?? ""} ${tool.inputSummary ?? ""}`;
      return /run_in_background["']?\s*[=:]\s*true|gh\s+pr\s+(?:create|merge|close)/.test(command);
    }) ?? false
  );
}

/// Each row's answer, kept while the row is the same object. Rows are immutable and a streamed
/// update replaces only the live ones, so a snapshot examines only the rows that changed.
const shown = new WeakMap<AcpmuxRow, boolean>();

/// Whether the summary has content: a row that shows in it, or an item of the chat's gallery.
/// The chat asks on every snapshot; the rows are checked first, from the cache, so the gallery
/// (which reads every row again) runs only for a chat with nothing else to show.
export function chatHasSummaryContent(rows: readonly AcpmuxRow[]): boolean {
  for (const row of rows) {
    let answer = shown.get(row);
    if (answer === undefined) shown.set(row, (answer = rowShowsInSummary(row)));
    if (answer) return true;
  }
  return chatGallery(rows).length > 0;
}
