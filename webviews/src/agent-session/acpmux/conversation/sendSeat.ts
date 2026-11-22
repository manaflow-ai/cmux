// Sent Prompt Placement `top` (chatDisplay.ts SEND_PLACEMENT_KEY; Leo, 2026-11-22: "the wider sweeping
// situation with having there be a bunch of extra space at the bottom is not something we need to
// emulate (other than our claude code customization emulation repo) but... dang it's CUTE and so much
// NICER FEELING than just a jarring instant send"). A prompt the reader sends from the latest message
// is seated at the top of the view, and the room under it stays empty for the reply to fill, as
// Claude Code's desktop app does: its transcript holds a min-height of `calc(100% + spare)` under the
// sent message (an "end hold") and puts the message's top 20 px under the view's top (`topOffsetPx:
// 20`); the reply grows down into the room, and once it passes the view's foot the view follows it
// again. Here the hold is the content's end: the followed view rests at the end, so an end held at
// the prompt's top plus a view puts the prompt at the top. Nothing is laid out for it (no spacer
// row, no min-height): the scroll content's height is the transcript's own `totalHeight`, which the
// placement pass already sets each pass.
//
// Cost: O(1) per pass once the prompt is found (its index is checked first); finding it reads back
// from the end to the newest prompt, the current turn's rows, and only after a send or when rows
// above it came or went (older history).
// Stop condition: one seat per chat at a time; the next send replaces it, another chat drops it, and a
// prompt no longer among the rows (a rewind) holds nothing.
import type { AcpmuxRow } from "../model";

/// How far under the view's top the seated prompt's row rests (px): Claude's own `topOffsetPx`, just
/// clear of the transcript's 18 px soft top edge (conversation.css `--acpmux-fade-top`).
export const SEAT_TOP_PX = 20;

/// A seat taken at a send. `before` is the newest prompt the rows held as it was sent: the first
/// newer prompt is the one sent, and binds the seat (`id`, `index`). `swept` once the view's rise to
/// it was drawn (VirtualTranscript `swept`).
export type SendSeat = {
  sessionId: string | undefined;
  before: string | undefined;
  id?: string;
  index?: number;
  lost?: true;
  swept?: true;
  /// The rise the sweep started with, while the send's own effect in the same commit is still to run.
  rise?: number;
};

const isPrompt = (row: AcpmuxRow, isLine: (row: AcpmuxRow) => boolean) => row.kind === "user" && !isLine(row);

/// The index of the seat's prompt among `rows`, binding the seat to the first prompt newer than
/// `before`; undefined while it has not come, or once it is gone (`lost`, so it is not looked for
/// again). Writes only the seat's own fields, and the same ones for the same rows: a render React
/// throws away and runs again binds it the same way.
export function seatIndex(
  seat: SendSeat,
  rows: readonly AcpmuxRow[],
  isLine: (row: AcpmuxRow) => boolean,
): number | undefined {
  if (seat.lost) return undefined;
  if (seat.id !== undefined) {
    if (seat.index !== undefined && rows[seat.index]?.id === seat.id) return seat.index;
    for (let at = rows.length - 1; at >= 0; at -= 1) {
      if (rows[at]!.id !== seat.id) continue;
      seat.index = at;
      return at;
    }
    seat.lost = true;
    return undefined;
  }
  // Not bound yet: the newest prompt, if it is not the one there was at the send.
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (!isPrompt(row, isLine)) continue;
    if (row.id === seat.before) return undefined;
    seat.id = row.id;
    seat.index = at;
    return at;
  }
  return undefined;
}

/// The content's end (scroll content height, px) a seat holds: the seated row's top, less
/// `SEAT_TOP_PX`, plus the view. `rowTop` is the row's top in the scroll content, the view's
/// floating top inset (`topInset`) taken out, so the row rests that inset plus SEAT_TOP_PX under the
/// scroller's top. 0 when nothing is seated.
export function seatEnd(rowTop: number | undefined, viewHeight: number): number {
  if (rowTop === undefined || !(viewHeight > 0)) return 0;
  return Math.max(0, rowTop - SEAT_TOP_PX) + viewHeight;
}
