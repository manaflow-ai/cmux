// The full-height thread minimap's model (ScrollMap.tsx): the rail spans the transcript's viewport
// and maps the whole scroll height onto it, so every message draws where it is in the chat. Pure
// functions over the transcript's layout, so nothing here measures a row.
import type { AcpmuxRow, ConversationLayout } from "../model";
import { THREAD_PADDING_TOP, type MinimapTurn } from "./model";

/// Space kept above and below the rail inside the transcript's viewport.
export const MAP_MARGIN = 12;
/// The rail shows once the chat has this many prompts and is taller than its viewport.
export const MAP_MIN_PROMPTS = 2;
/// A hover or press within this many px of a mark is on it; farther is on the track.
export const MAP_HIT = 6;
/// The bar for the view is never shorter than this, so a long chat's stays easy to grab.
export const MAP_MIN_THUMB = 18;
/// Replies closer than this on the rail draw as one mark (a long chat has thousands of rows).
const MERGE_PX = 3;
/// The fisheye by px from the pointer: marks within these distances grow by these shares.
const FISHEYE: ReadonlyArray<readonly [number, number]> = [
  [MAP_HIT, 1],
  [14, 0.6],
  [24, 0.3],
  [36, 0.12],
];

export type MapMark = {
  kind: "user" | "agent";
  /// The row's index in the transcript rows.
  row: number;
  /// The turn it belongs to (an index into the minimap's turns), or -1 before the first prompt.
  turn: number;
  /// Its center on the rail, px from the rail's top.
  y: number;
};

/// The first and last marks whose y lies in [top, bottom]. Marks are generated top to bottom, so
/// binary search keeps the scroll-frame update bounded by the visible map range instead of scanning
/// every row in a long transcript.
export function marksIn(
  marks: readonly MapMark[],
  top: number,
  bottom: number,
): { first: number; last: number } | undefined {
  let low = 0;
  let high = marks.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    if (marks[middle]!.y < top) low = middle + 1;
    else high = middle;
  }
  const first = low;
  if (first >= marks.length || marks[first]!.y > bottom) return undefined;

  low = first;
  high = marks.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    if (marks[middle]!.y <= bottom) low = middle + 1;
    else high = middle;
  }
  return { first, last: low - 1 };
}

/// Where content offset `top` (a row's layout top) draws on a rail `height` tall.
export function mapY(top: number, total: number, height: number): number {
  if (total <= 0 || height <= 0) return 0;
  return Math.max(0, Math.min(height, ((top + THREAD_PADDING_TOP) / (total + THREAD_PADDING_TOP)) * height));
}

/// The scroll offset whose view is centered on rail point `y`.
export function scrollTopAt(y: number, height: number, total: number, viewportHeight: number): number {
  const at = (Math.max(0, Math.min(height, y)) / Math.max(1, height)) * (total + THREAD_PADDING_TOP);
  return Math.max(0, Math.min(total - viewportHeight, at - viewportHeight / 2));
}

/// The bar for what is on screen: its top and height on the rail.
export function mapThumb(
  scrollTop: number,
  viewportHeight: number,
  total: number,
  height: number,
): { top: number; height: number } {
  const span = total + THREAD_PADDING_TOP;
  if (span <= 0 || height <= 0) return { top: 0, height: 0 };
  const size = Math.min(height, Math.max(MAP_MIN_THUMB, (viewportHeight / span) * height));
  const top = (Math.max(0, scrollTop) / span) * height;
  return { top: Math.max(0, Math.min(height - size, top)), height: size };
}

/// Every prompt's mark and every reply's (replies a few px apart merge into the first), top to
/// bottom. A prompt's mark is its turn's: `turns[i]` is the i-th user mark.
export function mapMarks(
  rows: readonly AcpmuxRow[],
  turns: readonly MinimapTurn[],
  layout: ConversationLayout,
  height: number,
): MapMark[] {
  const marks: MapMark[] = [];
  let turn = -1;
  let lastAgent = -Infinity;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user") {
      while (turn + 1 < turns.length && turns[turn + 1]!.index <= index) turn += 1;
      marks.push({ kind: "user", row: index, turn, y: mapY(layout.tops[index] ?? 0, layout.totalHeight, height) });
    } else if (row.kind === "assistant" && row.text) {
      const y = mapY(layout.tops[index] ?? 0, layout.totalHeight, height);
      if (y - lastAgent < MERGE_PX) continue;
      lastAgent = y;
      marks.push({ kind: "agent", row: index, turn, y });
    }
  }
  return marks;
}

/// The mark nearest rail point `y`, if one is within MAP_HIT px; a prompt wins a tie with a reply.
export function markAt(marks: readonly MapMark[], y: number): number | undefined {
  let best: number | undefined;
  let distance = MAP_HIT + 0.001;
  for (let index = 0; index < marks.length; index += 1) {
    const mark = marks[index]!;
    const off = Math.abs(mark.y - y);
    if (off < distance || (off === distance && mark.kind === "user")) {
      best = index;
      distance = off;
    }
    if (mark.y - y > MAP_HIT) break;
  }
  return best;
}

/// How much a mark `distance` px from the pointer grows (0 to 1); undefined is no pointer.
export function mapProgress(distance: number | undefined): number {
  if (distance === undefined) return 0;
  const off = Math.abs(distance);
  for (const [within, share] of FISHEYE) if (off <= within) return share;
  return 0;
}
