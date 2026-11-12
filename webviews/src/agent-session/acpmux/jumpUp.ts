// Jump up (design/transcript-overlays.md): the companion of Jump to latest. Jump to latest goes to
// the newest message; Jump up goes back to where the reader last was by their own hand (Leo,
// 2026-11-10: "you get jump to bottom, but then jump to, like, the last thread"):
//
// - the "New" line, while it is unread (the reader has a place to pick up from);
// - else the newer of the reader's last sent message and where they last scrolled and stopped.
//
// It shows only while that place is off screen. Pressed, it remembers where the view was; a second
// press or Esc goes back there. Pure: VirtualTranscript.tsx feeds it rows, offsets and presses.

import type { AcpmuxRow } from "./model";

/// A place in the transcript: a row and how far into it, layout px.
export type TranscriptPlace = { rowId: string; offset: number };

/// What the reader last did by hand: `sent` a prompt (its row), or `stopped` scrolling at a place.
export type ManualMark = { place: TranscriptPlace; at: number; why: "sent" | "stopped" };

/// Where the view was when Jump up was pressed: a second press or Esc goes back there.
export type JumpBack = { top: number; atLatest: boolean };

/// The newer of the two manual marks.
export function newerMark(a: ManualMark | undefined, b: ManualMark | undefined): ManualMark | undefined {
  if (!a) return b;
  if (!b) return a;
  return b.at >= a.at ? b : a;
}

/// Where Jump up goes: the unread line first (`sinceRowId`, while unread), else the newer manual mark.
export function jumpUpTarget(
  sinceRowId: string | undefined,
  sent: ManualMark | undefined,
  stopped: ManualMark | undefined,
): TranscriptPlace | undefined {
  if (sinceRowId !== undefined) return { rowId: sinceRowId, offset: 0 };
  return newerMark(sent, stopped)?.place;
}

/// Whether a place at `top` (layout px) lies outside the view `[viewTop, viewTop + viewHeight)`,
/// with `margin` px of the view's edges counted as off screen (the header and the dock cover them).
export function placeOffScreen(top: number | undefined, viewTop: number, viewHeight: number, margin = 0): boolean {
  if (top === undefined || !Number.isFinite(top)) return false;
  return top < viewTop + margin || top > viewTop + viewHeight - margin;
}

/// What the reader sees of the rows, in their layout px (VirtualTranscript.tsx): `shownTop` is the
/// layout offset at the view's top edge (the scroll offset less `lift`), and the rows draw `threadTop`
/// under their layout tops, below a floating tab row's `topInset`. The view is `height` tall and the
/// composer dock covers its last `dockSpace`.
export type RowsView = { shownTop: number; height: number; threadTop: number; topInset: number; dockSpace: number };

/// Whether a place at layout `top` is out of the reader's sight: above the view's top edge, or under the
/// dock. Measured where the row draws, not at its bare layout top: that counted the first prompt of a chat
/// scrolled a few px off screen while the whole bubble was in plain sight, and Jump up stood over the
/// running turn's live line (gallery agent-pane.transcript#codex-turn-raw-commands).
export function placeOffView(top: number | undefined, view: RowsView): boolean {
  if (top === undefined) return false;
  return placeOffScreen(top + view.threadTop, view.shownTop, view.height - view.topInset - view.dockSpace);
}

/// Where a press goes: back to `back` when one is held (the second press), else to the target,
/// holding where the view is now.
export type JumpUpPress = { kind: "back"; back: JumpBack } | { kind: "go"; back: JumpBack };
export function pressJumpUp(held: JumpBack | undefined, now: JumpBack): JumpUpPress {
  return held ? { kind: "back", back: held } : { kind: "go", back: now };
}

/// The button's state: up (go to the place) or back (return), and whether it shows.
/// It shows while the place is off screen, and while a return is held (so the second press is there).
export function jumpUpShown(offScreen: boolean, held: JumpBack | undefined): boolean {
  return offScreen || held !== undefined;
}

/// Whether a row is a prompt the reader sent by hand: not another agent's message, a task's result,
/// harness bookkeeping or the Chief's message to a subagent (`incoming`, `untyped`, `from`), and in a
/// shared chat not another person's. `me` is the author id this pane sends as
/// (multiplayer/presenceClient.ts `selfId`); the owner's prompts carry no author and acpmux names the
/// owner `owner`.
export function ownPrompt(row: AcpmuxRow, me = "owner"): boolean {
  if (row.kind !== "user" || row.incoming || row.untyped || row.from !== undefined) return false;
  return (row.author?.id ?? "owner") === me;
}

/// What `lastOwnPrompt` read last: whose prompts, how many rows, the last one's id, and the prompt
/// it found.
export type PromptScan = { me?: string; length: number; lastId?: string; found?: { id: string; at: number } };

/// The reader's newest own prompt (`ownPrompt`), Jump up's `sent` mark. The transcript mostly
/// appends: when the rows read last are still the head of these, only the rows after them are
/// scanned, so a render costs O(new rows); otherwise (another chat, a rebuild, another author id)
/// one scan back from the end, which stops at the first own prompt.
export function lastOwnPrompt(
  rows: readonly AcpmuxRow[],
  scan: { current: PromptScan },
  me = "owner",
): { id: string; at: number } | undefined {
  const last = scan.current;
  const appended =
    last.me === me && last.length > 0 && rows.length >= last.length && rows[last.length - 1]?.id === last.lastId;
  const from = appended ? last.length : 0;
  let found = appended ? last.found : undefined;
  for (let i = rows.length - 1; i >= from; i--) {
    const row = rows[i]!;
    if (ownPrompt(row, me)) {
      found = { id: row.id, at: row.at };
      break;
    }
  }
  scan.current = { me, length: rows.length, lastId: rows[rows.length - 1]?.id, found };
  return found;
}
