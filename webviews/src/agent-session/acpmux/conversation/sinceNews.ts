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

/// The most messages the line counts: past it the label reads "999+", and counting stays bounded
/// however long the chat ran while the person was away.
export const SINCE_COUNT_CAP = 999;

/// How many rows of any kind `sinceCount` reads per message it may count: status lines and tool runs
/// between replies are read past, never counted.
const ROWS_PER_MESSAGE = 16;

/// What one news row counts as: a "Received N messages" run is its N, every other news row one.
const messagesIn = (row: AcpmuxRow): number =>
  row.kind === MESSAGE_RUN ? Math.max(1, row.messageRun?.received ?? 1) : 1;

/// How many messages are under the line at `index` in `rows` (the drawn rows), for its "157 new
/// messages" label (Leo, 2026-11-15, of the terminal chat's rule: "we needto properly do somthing
/// like this in the gui somehow"). A message is what `isNews` reads as news, so a line that draws
/// counts at least one. Read from the end back to the line and bounded, so a chat that ran all day
/// costs the same per update as one that ran a minute: past `cap` it answers `cap` + 1 (the label's
/// "999+"); past `ROWS_PER_MESSAGE` times as many rows of any kind it answers `undefined` (the label
/// reads "New": no number it cannot stand by). `undefined` too when `index` is not the line.
export function sinceCount(rows: readonly AcpmuxRow[], index: number, cap = SINCE_COUNT_CAP): number | undefined {
  if (rows[index]?.kind !== SINCE_DIVIDER) return undefined;
  const stop = Math.max(index, rows.length - 1 - cap * ROWS_PER_MESSAGE);
  let count = 0;
  for (let at = rows.length - 1; at > stop; at -= 1) {
    const row = rows[at]!;
    if (isNews(row)) count += messagesIn(row);
    if (count > cap) return cap + 1;
  }
  return stop === index ? count : undefined;
}
