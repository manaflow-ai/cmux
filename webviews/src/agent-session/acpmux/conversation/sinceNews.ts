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
import { indexOfRow } from "../transcript/rowIndex";

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

/// Whether `row` came from someone else: another person's or agent's message (on its own, in a batch,
/// in a "Received N messages" run, waiting in the queue, or folded under a turn's line as its
/// prompt). The agent's own replies and asks in a running turn are not (`HeldSpan`).
export function isOthersNews(row: AcpmuxRow): boolean {
  if (row.foldedPrompt && isOthersNews(row.foldedPrompt)) return true;
  if (row.kind === MESSAGE_RUN) return (row.messageRun?.received ?? 0) > 0;
  if (row.kind === LANE_NOTICE_BATCH || row.kind === QUEUED_MESSAGE || row.kind === PENDING_MESSAGES) return true;
  if (row.kind !== "user") return false;
  const kind = row.incoming?.kind;
  return kind === "message" || kind === "notice" || kind === "inbox";
}

/// A turn's own rows, held back from the line: indices [from, to) of the drawn rows. Leo,
/// 2026-11-25: "i think the new messages thing may be redundant if there is an unfinished turn.
/// like dont mark it as new if it's still going". While the agent's turn runs, what it writes is
/// not new, and a turn that ends while the reader is at its bottom was read as it came
/// (`SinceTurnHold`). Only other people's and agents' messages in a held span count (`isOthersNews`).
/// `seen`: rows that came in while the reader was at the latest row; none of them counts, others'
/// messages included.
export type HeldSpan = { from: number; to: number; seen?: true };
const NO_SPANS: readonly HeldSpan[] = [];

/// Whether `row` at `at` is news to the line: held rows count only when they came from others.
const newsAt = (row: AcpmuxRow, at: number, held: readonly HeldSpan[]): boolean => {
  for (const span of held) if (at >= span.from && at < span.to) return !span.seen && isOthersNews(row);
  return isNews(row);
};

/// Whether the line at `index` in `rows` (the drawn rows) has news under it. Stops at the first
/// news row, so a chat that answered reads one or two rows. `held`: spans of turns whose own rows
/// are not news (`HeldSpan`).
export function sinceNews(rows: readonly AcpmuxRow[], index: number, held: readonly HeldSpan[] = NO_SPANS): boolean {
  const line = rows[index];
  if (line?.kind !== SINCE_DIVIDER) return false;
  if (line.since?.recap) return true;
  const end = Math.min(rows.length, index + 1 + SINCE_NEWS_REACH);
  for (let at = index + 1; at < end; at += 1) if (newsAt(rows[at]!, at, held)) return true;
  // Past the reach, a run of rows still counts as news, unless all of it is a held turn.
  return end < rows.length && !held.some((span) => span.from <= end && span.to >= rows.length);
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
/// `held`: spans of turns whose own rows are not counted (`HeldSpan`).
export function sinceCount(
  rows: readonly AcpmuxRow[],
  index: number,
  cap = SINCE_COUNT_CAP,
  held: readonly HeldSpan[] = NO_SPANS,
): number | undefined {
  if (rows[index]?.kind !== SINCE_DIVIDER) return undefined;
  const stop = Math.max(index, rows.length - 1 - cap * ROWS_PER_MESSAGE);
  let count = 0;
  for (let at = rows.length - 1; at > stop; at -= 1) {
    const row = rows[at]!;
    if (newsAt(row, at, held)) count += messagesIn(row);
    if (count > cap) return cap + 1;
  }
  return stop === index ? count : undefined;
}

/// The most rows `runningTurnFrom` reads back from the end: a running turn longer than this is held
/// from the line down, so the scan stays bounded however long the turn runs.
const RUNNING_TURN_REACH = SINCE_COUNT_CAP * ROWS_PER_MESSAGE;

/// Where the running turn starts in `rows` (the drawn rows), at or after the row under the line at
/// `index`: the row after the last turn's end (its footer, `turnSummary`), or after the last row of
/// another turn (`turnId`). Read from the end back, bounded.
export function runningTurnFrom(rows: readonly AcpmuxRow[], index: number): number {
  const floor = Math.max(index, rows.length - 1 - RUNNING_TURN_REACH);
  let turn: string | undefined;
  for (let at = rows.length - 1; at > floor; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "turnSummary") return at + 1;
    if (row.kind === "assistant" && row.turnId !== undefined) {
      turn ??= row.turnId;
      if (row.turnId !== turn) return at + 1;
    }
  }
  return index + 1;
}

/// Which turns' own rows the line holds back (`HeldSpan`; Leo, 2026-11-25: "dont mark it as new if
/// it's still going"). One per transcript, read once per render with the line's mark:
/// - while a turn runs, its rows under the line are held: its replies draw no line, no count and no
///   banner, while others' messages in it still do;
/// - when it ends with the reader at the latest row, they read it as it came: it stays held for that
///   mark, so the line does not light up over it after the fact;
/// - when it ends with the reader scrolled away, it is let go: what they did not see is new;
/// - any news that comes in under the line while the reader is at the latest row (another agent's
///   message, a reply after the turn) they read as it came: held too, so no line, count or banner
///   lights up at the bottom they are looking at (Leo, 2026-11-25: "idk why it even happened in the
///   first place for new to appear at the bottom"). What was under the line when it was placed stays
///   news.
/// Rows are kept by id, so a page loaded above or shed rows never move a span. O(spans) per render,
/// plus one bounded scan back to the running turn's start while one runs.
export class SinceTurnHold {
  private mark?: string;
  /// The running turn's first news row under the line, while one runs.
  private running?: string;
  /// Turns that ended while the reader followed: their first and last news rows.
  private read: {
    from: string;
    through: string;
    hints: [{ current: number }, { current: number }];
    seen?: true;
  }[] = [];
  /// The latest news row under the line as of the last read, and whether it has been read yet.
  private latest?: string;
  private latestHint = { current: -1 };
  /// Whether `latest` has been read with the line drawn (what was under it then stays news).
  private based = false;

  spans(
    rows: readonly AcpmuxRow[],
    index: number,
    mark: string | undefined,
    working: boolean,
    following: boolean,
  ): readonly HeldSpan[] {
    if (mark !== this.mark) {
      this.mark = mark;
      this.running = undefined;
      this.read = [];
      this.latest = undefined;
      this.latestHint = { current: -1 };
      this.based = false;
    }
    if (mark === undefined || index < 0) return NO_SPANS;
    this.followArrivals(rows, index, following);
    if (!working && this.running !== undefined) {
      // The turn's own news it ended on: its first and last reply (ids that stay, never a live line's).
      const hint = { current: -1 };
      const start = indexOfRow(rows, this.running, hint);
      let through: string | undefined;
      for (let at = rows.length - 1; at >= start && start >= 0 && through === undefined; at -= 1)
        if (isNews(rows[at]!)) through = rows[at]!.id;
      if (following && through !== undefined)
        this.read.push({ from: this.running, through, hints: [hint, { current: -1 }] });
      this.running = undefined;
    }
    const spans: HeldSpan[] = [];
    for (const turn of this.read) {
      const from = indexOfRow(rows, turn.from, turn.hints[0]);
      const through = indexOfRow(rows, turn.through, turn.hints[1]);
      if (from >= 0 && through >= from)
        spans.push({ from, to: through + 1, ...(turn.seen && { seen: true as const }) });
    }
    if (working) {
      const from = runningTurnFrom(rows, index);
      if (from < rows.length) {
        if (this.running === undefined)
          for (let at = from; at < rows.length && this.running === undefined; at += 1)
            if (isNews(rows[at]!)) this.running = rows[at]!.id;
        spans.push({ from, to: rows.length });
      }
    }
    return spans.length > 0 ? spans : NO_SPANS;
  }

  /// News that came in under the line since the last read, with the reader at the latest row: read
  /// as it came. A run of such arrivals grows one span. Bounded: one scan back from the end to the
  /// latest news row (at most SINCE_NEWS_REACH rows), one to where the new run starts.
  private followArrivals(rows: readonly AcpmuxRow[], index: number, following: boolean): void {
    const floor = Math.max(index, rows.length - 1 - SINCE_NEWS_REACH);
    let latestAt = -1;
    for (let at = rows.length - 1; at > floor && latestAt < 0; at -= 1) if (isNews(rows[at]!)) latestAt = at;
    const latest = latestAt >= 0 ? rows[latestAt]!.id : undefined;
    const before = this.latest;
    const beforeAt = before === undefined ? -1 : indexOfRow(rows, before, this.latestHint);
    this.latest = latest;
    this.latestHint = { current: latestAt };
    const based = this.based;
    this.based = true;
    if (!based || !following || latest === undefined || latest === before) return;
    // Only rows that came in after the last news row read: a page of history loaded under the line
    // (the last one read gone, or now below the latest) is never taken as seen. Where the run starts:
    // the first news row after the last one read, else the latest alone, never more than came in.
    if (before !== undefined && beforeAt >= 0 && beforeAt > latestAt) return;
    let fromAt = latestAt;
    if (before === undefined || beforeAt >= 0)
      for (let at = Math.max(beforeAt, index) + 1; at < latestAt; at += 1)
        if (isNews(rows[at]!)) {
          fromAt = at;
          break;
        }
    const last = this.read[this.read.length - 1];
    if (last?.seen && before !== undefined && last.through === before) {
      last.through = latest;
      last.hints[1] = { current: latestAt };
      return;
    }
    this.read.push({
      from: rows[fromAt]!.id,
      through: latest,
      hints: [{ current: fromAt }, { current: latestAt }],
      seen: true,
    });
  }
}
