// The sticky prompt's model: which prompt the view is in, and how far its header sits from being
// pushed out. Pure and O(log prompts) per scroll: the prompt indexes are kept per rows change
// (appends extend them), and each scroll is one binary search over their tops.
import type { AcpmuxRow } from "../model";

export type PromptScanState = {
  length: number;
  lastId?: string;
  indexes: number[];
};

/// A prompt row the reader typed (not a hidden or incoming notice).
export function isPrompt(row: AcpmuxRow): boolean {
  return row.kind === "user" && row.incoming === undefined && !row.untyped && Boolean(row.text?.trim());
}

/// The prompt rows' indexes. The transcript mostly appends: when the rows read last are still the
/// head of these, only the rows after them are scanned.
export function promptIndexes(rows: readonly AcpmuxRow[], last: PromptScanState): PromptScanState {
  const appended = last.length > 0 && rows.length >= last.length && rows[last.length - 1]?.id === last.lastId;
  if (appended && rows.length === last.length) return last;
  const indexes = appended ? last.indexes.slice() : [];
  for (let i = appended ? last.length : 0; i < rows.length; i++) if (isPrompt(rows[i]!)) indexes.push(i);
  return { length: rows.length, lastId: rows[rows.length - 1]?.id, indexes };
}

/// The position in `indexes` of the last prompt whose top is at or above `y`, or -1.
export function promptAt(indexes: readonly number[], topAt: (index: number) => number, y: number): number {
  let lo = 0;
  let hi = indexes.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (topAt(indexes[mid]!) <= y) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found;
}

export type StickyState = {
  /// The prompt the view is in (its slot in `indexes`), -1 before the first.
  slot: number;
  /// The row index of that prompt.
  index: number;
  /// Whether its own row has scrolled out above the view, so a header stands in for it.
  pinned: boolean;
  /// Space from the header's top to the next prompt's row, px (Infinity when none in view): the push.
  room: number;
};

export function stickyState(
  indexes: readonly number[],
  geometry: {
    topAt: (index: number) => number;
    heightAt: (index: number) => number;
  },
  viewTop: number,
  viewHeight: number,
): StickyState {
  const slot = promptAt(indexes, geometry.topAt, viewTop);
  if (slot < 0) return { slot, index: -1, pinned: false, room: Infinity };
  const index = indexes[slot]!;
  const bottom = geometry.topAt(index) + geometry.heightAt(index);
  const next = indexes[slot + 1];
  const nextTop = next === undefined ? Infinity : geometry.topAt(next) - viewTop;
  return {
    slot,
    index,
    pinned: bottom < viewTop,
    room: nextTop > viewHeight ? Infinity : nextTop,
  };
}
