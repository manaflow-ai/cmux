// The transcript's one jump control and what it reads (design/transcript-overlays.md,
// VirtualTranscript.tsx JumpToLatest). Ported from #40813's jumpControl.ts (Leo, 2026-11-10: "There's
// also no point doubling up on this" and "this should be more selective"), now on the seen cursor
// (Leo, 2026-11-12: "it doesn't actually keep track of, like, when the things ... when you restart
// the update, all of a sudden it's just, like, you know, it's there and it's noisy").
//
// Seen is one cursor per chat per person, `readThrough`, a log seq acpmux keeps (hub/seen.rs
// `read_through`). Only the page's `_acpmux/seen` moves it, forward, with the newest row that was in
// view while the reader attended the chat (direct.ts `noteVisibleThrough`). Unseen rows are the rows
// after it by an agent or another person; the reader's own prompts and notice, status and mux rows
// never are. So:
// - `up`: an unseen row lies wholly above the view: the disc points up, a press lands that row near
//   the top;
// - `latest`: away from the latest message (or a chat this one started waits on an answer): down;
// - `hidden`: neither. A restart, an update or a reconnect moves no cursor, so with nothing new
//   there is no arrow.
// Pure, and every per-frame read is O(1) or O(log n): VirtualTranscript.tsx feeds it rows, the
// layout and where the view is. God chats hold tens of thousands of rows.

import type { LayoutGeometry } from "./conversationGeometry";
import type { AcpmuxRow } from "./model";
import { ownPrompt } from "./jumpUp";

export type JumpControl = { kind: "up" } | { kind: "latest" } | { kind: "hidden" };

/// The kinds an agent writes into the transcript: its words, thinking, calls, plan, images and the
/// messages other agents sent it. Everything else (notices, status, turn footers, compaction,
/// the "New" line, typing, queued prompts) is the chat's bookkeeping, never something to catch up on.
/// `"messageRun"` is model.ts `MESSAGE_RUN`, written out: model.ts reaches this module through its
/// imports, so reading its binding while this module loads throws.
const AGENT_KINDS: ReadonlySet<string> = new Set([
  "assistant",
  "thought",
  "tool",
  "activity",
  "plan",
  "image",
  "resource",
  "message",
  "messageRun",
]);

/// Whether `row` counts as unseen once it lies after the cursor: an agent's row, or a prompt by
/// another person or agent. `me` is the author id this pane sends as (jumpUp.ts `ownPrompt`).
export function countsUnseen(row: AcpmuxRow, me = "owner"): boolean {
  if (row.kind === "user") {
    if (row.untyped) return false;
    const incoming = row.incoming?.kind;
    if (incoming === "notice" || incoming === "hidden") return false;
    return !ownPrompt(row, me);
  }
  return AGENT_KINDS.has(row.kind);
}

/// The seq a row sorts by: its own, else the nearest row's before it within a few rows (a row the
/// view derives, a fold or a group, may carry none). Undefined when none is near.
function seqNear(rows: readonly AcpmuxRow[], index: number): number | undefined {
  for (let at = index; at >= 0 && at > index - 8; at -= 1) {
    const seq = rows[at]?.seq;
    if (seq !== undefined) return seq;
  }
  return undefined;
}

/// The first index whose seq is above `seq` (rows sort by the record that began them, direct.ts
/// `OrderedRows`), by binary search: O(log n).
export function firstIndexAfter(rows: readonly AcpmuxRow[], seq: number): number {
  let lo = 0;
  let hi = rows.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    const at = seqNear(rows, mid);
    if (at === undefined || at <= seq) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/// What `firstUnseen` read last, so the next read of mostly the same rows costs O(new rows).
export type UnseenScan = {
  rows?: readonly AcpmuxRow[];
  length: number;
  lastId?: string;
  readThrough?: number;
  me?: string;
  /// The index found, -1 when every counted row was seen; `from` where its scan stopped.
  found: number;
  from: number;
};

export const emptyUnseenScan = (): UnseenScan => ({ length: 0, found: -1, from: 0 });

/// The index of the first unseen row (`countsUnseen`, seq above `readThrough`), -1 when none.
/// Amortized O(1) per render: rows mostly append and the cursor only moves forward, so a read picks
/// up where the last stopped; another chat, a rebuild or a cursor moved back reads again from a
/// binary search. Undefined `readThrough` (not known yet): none.
export function firstUnseen(
  rows: readonly AcpmuxRow[],
  readThrough: number | undefined,
  scan: { current: UnseenScan },
  me = "owner",
): number {
  if (readThrough === undefined) {
    scan.current = emptyUnseenScan();
    return -1;
  }
  const last = scan.current;
  const same = last.me === me && last.readThrough !== undefined;
  const appended =
    same &&
    last.length > 0 &&
    rows.length >= last.length &&
    rows[last.length - 1]?.id === last.lastId &&
    (last.found < 0 || rows[last.found]?.id === last.rows?.[last.found]?.id);
  let found: number;
  let from: number;
  if (appended && readThrough === last.readThrough) {
    // Same cursor, rows appended (or changed in place): the first stays first; else scan the new.
    found = last.found;
    from = last.from;
  } else if (appended && readThrough > last.readThrough! && last.found >= 0) {
    // The cursor moved on: from the row found, past what it now covers.
    found = -1;
    from = Math.max(last.found, firstIndexAfter(rows, readThrough));
  } else {
    found = -1;
    from = firstIndexAfter(rows, readThrough);
  }
  if (found < 0) {
    for (; from < rows.length; from += 1) {
      const row = rows[from]!;
      if ((row.seq === undefined || row.seq > readThrough) && countsUnseen(row, me)) {
        found = from;
        break;
      }
    }
  }
  scan.current = { rows, length: rows.length, lastId: rows.at(-1)?.id, readThrough, me, found, from };
  return found;
}

/// The rows the reader sees, in layout px: rows `first` to `last` (inclusive) cross the band from
/// `top` to `bottom`. O(log n) (`upperBoundTop`). None (`first > last`) when there are no rows.
export function visibleRows(
  geometry: Pick<LayoutGeometry, "count" | "upperBoundTop" | "topAt" | "heightAt">,
  top: number,
  bottom: number,
): { first: number; last: number } {
  if (geometry.count === 0 || bottom <= top) return { first: 0, last: -1 };
  // The row holding `top`: the last whose top is at or above it, unless it ends above it.
  let first = Math.max(0, geometry.upperBoundTop(top) - 1);
  if (first < geometry.count - 1 && geometry.topAt(first) + geometry.heightAt(first) <= top) first += 1;
  const last = Math.min(geometry.count - 1, Math.max(first, geometry.upperBoundTop(bottom - 1) - 1));
  return { first, last };
}

/// How many rows in view `seenThrough` looks back through for one that counts: a view holds far
/// fewer, so this only bounds a frame's work.
const VIEW_SCAN = 64;

/// Where the cursor may move from what is in view: the newest row in view that counts
/// (`countsUnseen`; a notice or status row at the bottom moves nothing), unless an unseen row lies
/// above the view (the reader has not been there: everything after it stays unseen), and never past
/// an unseen row below it. Undefined: nothing to move it to.
export function seenThrough(
  rows: readonly AcpmuxRow[],
  view: { first: number; last: number },
  unseen: number,
  me = "owner",
): number | undefined {
  if (view.last < view.first) return undefined;
  if (unseen >= 0 && unseen < view.first) return undefined;
  let newest: number | undefined;
  for (let at = view.last; at >= view.first && at > view.last - VIEW_SCAN; at -= 1) {
    const row = rows[at];
    if (row && countsUnseen(row, me)) {
      newest = seqNear(rows, at);
      break;
    }
  }
  if (newest === undefined) return undefined;
  const below = unseen > view.last ? rows[unseen]?.seq : undefined;
  return below !== undefined ? Math.min(newest, below - 1) : newest;
}

/// How far over the first unseen row the "New" line may sit and still be where a press lands.
const LINE_SCAN = 32;

/// Where a press lands: the "New" line at `since` when nothing that counts lies between it and the
/// first unseen row at `index` (the reader's own prompt, a notice, a turn's bookkeeping rows may),
/// so the line shows with that row under it; else the row itself. Reads at most `LINE_SCAN` rows.
export function lineOver(rows: readonly AcpmuxRow[], index: number, since: number, me = "owner"): number {
  if (since < 0 || since >= index || index - since > LINE_SCAN) return index;
  for (let at = since + 1; at < index; at += 1) {
    const row = rows[at];
    if (row && countsUnseen(row, me)) return index;
  }
  return since;
}

/// The control's state. An ask waiting below (or in a chat this one started) comes first: the reader
/// is needed there, and the disc is the Needs you pill then. Then up, only while an unseen row lies
/// above the view; then Jump to latest while away from the latest message.
export function jumpControl({
  unseenAbove,
  behind,
  asks,
  asksElsewhere,
}: {
  unseenAbove: boolean;
  behind: boolean;
  asks: number;
  asksElsewhere: number;
}): JumpControl {
  if (asks > 0 && (behind || asksElsewhere > 0)) return { kind: "latest" };
  if (unseenAbove) return { kind: "up" };
  if (behind || asksElsewhere > 0) return { kind: "latest" };
  return { kind: "hidden" };
}

/// How many turns the unseen rows from `unseen` span, for the count badge: the turn footers after
/// it, and the turn still running past the last one. O(rows after it); read only for that badge.
export function unseenTurns(rows: readonly AcpmuxRow[], unseen: number): number {
  if (unseen < 0) return 0;
  let turns = 0;
  let open = false;
  for (let at = unseen; at < rows.length; at += 1) {
    const row = rows[at]!;
    if (row.kind === "turnSummary") {
      turns += 1;
      open = false;
    } else if (AGENT_KINDS.has(row.kind)) open = true;
  }
  return Math.max(1, turns + (open ? 1 : 0));
}
