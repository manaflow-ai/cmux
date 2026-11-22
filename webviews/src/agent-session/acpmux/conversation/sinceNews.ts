// Whether "New since you looked" has anything new to read under it (SinceDivider.tsx). acpmux counts
// a turn as unread when it ends unseen, and also when the reader comes back from idle while a turn
// still runs that wrote anything after where they left off (hub/seen.rs `count_running_turn`). That
// write can be one status line: a subagent's "started working" drew the line over nothing (Leo,
// 2026-11-22: "this is a bad new. it shouldnt just do this like this when there's nothing").
//
// News is what the reader reads: a reply with words, another agent's message to this chat (on its
// own, in a batch, in a "Received N messages" run, waiting in the queue, or folded under the turn's
// Working for line as the prompt that started it), and a question or permission the agent asks.
// Not news: status lines (a subagent starting or ending, a background task, a tool run, a
// compaction), the turn's own chrome (Working for, Worked for, the footer) and the person's own
// prompts. A recap on the line is news too (it is content).
import {
  type AcpmuxRow,
  LANE_NOTICE_BATCH,
  MESSAGE_RUN,
  PENDING_MESSAGES,
  QUEUED_MESSAGE,
  SINCE_DIVIDER,
} from "../model";
import { PERMISSION_RECORD } from "../permissions/record";
import { QUESTION_RECORD } from "../question/record";

/// How many rows under the line are read at most: a run of status lines longer than this is rare
/// enough to count as news, and keeps the scan bounded however long the chat grows.
export const SINCE_NEWS_REACH = 256;

/// Whether `row` is something new to read.
export function isNews(row: AcpmuxRow): boolean {
  if (row.foldedPrompt && isNews(row.foldedPrompt)) return true;
  if (row.kind === "assistant") return (row.text ?? "").trim().length > 0;
  if (row.kind === MESSAGE_RUN) return (row.messageRun?.received ?? 0) > 0;
  if (row.kind === LANE_NOTICE_BATCH || row.kind === QUEUED_MESSAGE || row.kind === PENDING_MESSAGES) return true;
  if (row.kind === "user") {
    const kind = row.incoming?.kind;
    return kind === "message" || kind === "notice" || kind === "inbox";
  }
  return row.kind === QUESTION_RECORD || row.kind === PERMISSION_RECORD;
}

/// Whether the line at `index` in `rows` (the drawn rows) has news under it. Stops at the first
/// news row, so a chat that answered reads one or two rows.
export function sinceNews(rows: readonly AcpmuxRow[], index: number): boolean {
  const line = rows[index];
  if (line?.kind !== SINCE_DIVIDER) return false;
  if (line.since?.recap) return true;
  const end = Math.min(rows.length, index + 1 + SINCE_NEWS_REACH);
  for (let at = index + 1; at < end; at += 1) if (isNews(rows[at]!)) return true;
  return end < rows.length;
}
