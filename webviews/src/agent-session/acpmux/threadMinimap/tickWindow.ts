// Which of the compact rail's rows are in the DOM. A long chat has a row per prompt (1,000 for a
// 2,000-row chat), and every layout the transcript forces (it measures its rows on each commit)
// laid out all of them: the rail cost 34 ms per frame at p95 while scrolling such a chat and 42 ms
// while a reply streamed (bench/thread-minimap-frame-cost.bench.ts). The rail draws only the rows
// in its own view, with some past each edge, and the rows focus or a card needs; spacers keep the
// list as tall as all of its rows, so its scroll, the fades and every row's place stay the same.
import { ROW_PITCH } from "./model";

/// Rows past each edge of the rail's view that stay drawn, so a scroll or a glide of a few rows
/// shows rows already laid out.
export const TICK_OVERSCAN = 12;

/// Half-open ranges of row indexes to draw, sorted and disjoint: the rows the list's view shows
/// (`listTop`, `height` in px) with TICK_OVERSCAN past each edge, plus each of `keep` (the focused,
/// hovered and described rows, which must stay mounted for focus and aria).
export function tickRanges(
  count: number,
  listTop: number,
  height: number,
  keep: ReadonlyArray<number | undefined> = [],
): Array<[number, number]> {
  if (count <= 0) return [];
  // An offset past the list's end (it had more rows: another chat, before its scroll catches up)
  // reads as the end, so the rows draw.
  const top = Math.max(0, Math.min(listTop, count * ROW_PITCH - Math.max(0, height)));
  const first = Math.max(0, Math.floor(top / ROW_PITCH) - TICK_OVERSCAN);
  const last = Math.min(count, Math.ceil((top + Math.max(0, height)) / ROW_PITCH) + TICK_OVERSCAN);
  const ranges: Array<[number, number]> = [[first, Math.max(first, last)]];
  for (const index of keep)
    if (index !== undefined && index >= 0 && index < count && (index < first || index >= last))
      ranges.push([index, index + 1]);
  ranges.sort((a, b) => a[0] - b[0]);
  const merged: Array<[number, number]> = [];
  for (const range of ranges) {
    const previous = merged.at(-1);
    if (previous && range[0] <= previous[1]) previous[1] = Math.max(previous[1], range[1]);
    else if (range[1] > range[0]) merged.push([range[0], range[1]]);
  }
  return merged;
}
