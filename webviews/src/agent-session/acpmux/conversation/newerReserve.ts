// Room below a transcript's rows for the newer history a reader scrolled far up let go of (direct.ts
// `shedNewerHeld`), as olderReserve.ts holds room above them for the older history not loaded yet.
//
// A window whose newest records go takes their rows from below the view: without the room the content would end
// at the window's last row, and the scrollbar's thumb would grow and slide down at each shed and shrink back as
// each page read forward (`loadNewer`) lands. While newer history is left the content keeps the height it had
// when the rows last reached the chat's end: rows that leave give their height to the room, rows that come (or
// draw taller) take theirs out of it. No estimate is made: the rows that left were laid out before they went.
// O(1) a pass.

import type { AcpmuxRow } from "../model";

export type NewerReserve = {
  sessionId?: string;
  /// The content's height held while newer history is left: the rows' and the room under them.
  total: number;
  /// The room held under the rows this pass.
  room: number;
};

/// The room under rows `height` tall (their layout total, the room above them included) after the pass before
/// (`previous`). None while the rows reach the chat's end (`canLoadNewer` false) or for another chat; then the
/// height is what a later window holds.
export function newerReserve(
  previous: NewerReserve | undefined,
  next: { sessionId?: string; height: number; canLoadNewer: boolean },
): NewerReserve {
  const { sessionId, height, canLoadNewer } = next;
  const same = previous?.sessionId === sessionId ? previous : undefined;
  if (!canLoadNewer || !same) return { sessionId, total: height, room: 0 };
  // Rows past the held height (the room ran out): the content grows with them, and holds that.
  const total = Math.max(same.total, height);
  return { sessionId, total, room: total - height };
}

/// The height of the rows that left the top of `before` (a window letting go of its oldest held records, direct.ts
/// `shedWindowTop`): the top among `before` of the row `rows` now starts with. 0 when no row left the top (the same
/// first row, a page that landed above it, or another set of rows). O(the rows before the new first row).
export function heightLeftAbove(
  before: readonly AcpmuxRow[],
  top: (index: number) => number,
  rows: readonly AcpmuxRow[],
): number {
  const first = rows[0]?.id;
  if (first === undefined || before.length === 0 || before[0]!.id === first) return 0;
  for (let at = 1; at < before.length; at += 1) if (before[at]!.id === first) return Math.max(0, top(at) - top(0));
  return 0;
}

/// Whether `rows` share no row with `before` at either end (another page of the chat is held now): their first and
/// last rows are neither among the other's. O(1) when an end is the same row, else O(rows).
export function rowsReplaced(before: readonly AcpmuxRow[], rows: readonly AcpmuxRow[]): boolean {
  if (before.length === 0 || rows.length === 0) return false;
  if (before[0]!.id === rows[0]!.id || before.at(-1)!.id === rows.at(-1)!.id) return false;
  const ids = new Set(rows.map((row) => row.id));
  return !ids.has(before[0]!.id) && !ids.has(before.at(-1)!.id);
}
