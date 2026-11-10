// Jump up (design/transcript-overlays.md): the companion of Jump to latest. Jump to latest goes to
// the newest message; Jump up goes back to where the reader last was by their own hand (Leo,
// 2026-11-10: "you get jump to bottom, but then jump to, like, the last thread"):
//
// - the "New" line, while it is unread (the reader has a place to pick up from);
// - else the newer of the reader's last sent message and where they last scrolled and stopped.
//
// It shows only while that place is off screen. Pressed, it remembers where the view was; a second
// press or Esc goes back there. Pure: VirtualTranscript.tsx feeds it rows, offsets and presses.

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
