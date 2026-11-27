// Jump up's reads of a row and a place (design/transcript-overlays.md). Jump up itself is the one
// jump control turned up (jumpControl.ts): it goes only to the first row the reader has not seen,
// never to their last prompt or where they last stopped scrolling (Leo, 2026-11-10: "this should be
// more selective"), so it holds no way back either. Pure.

import type { AcpmuxRow } from "./model";

/// A place in the transcript: a row and how far into it, layout px.
export type TranscriptPlace = { rowId: string; offset: number };

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

/// Whether a row is a prompt the reader sent by hand: not another agent's message, a task's result,
/// harness bookkeeping or the Chief's message to a subagent (`incoming`, `untyped`, `from`), and in a
/// shared chat not another person's. `me` is the author id this pane sends as
/// (multiplayer/presenceClient.ts `selfId`); the owner's prompts carry no author and acpmux names the
/// owner `owner`.
export function ownPrompt(row: AcpmuxRow, me = "owner"): boolean {
  if (row.kind !== "user" || row.incoming || row.untyped || row.from !== undefined) return false;
  return (row.author?.id ?? "owner") === me;
}
