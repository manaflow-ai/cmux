import type { AcpmuxRow } from "../model";
import { geometryOf, type GeometrySource } from "../conversationGeometry";

/** Keep the follow correction small enough to absorb layout rounding, but not a real measured gap. */
export const FOLLOW_BOTTOM_DEADBAND_PX = 4;

/// Whether the transcript fades above the composer: more lies below than follow's deadband, so a
/// view resting at its end keeps a plain edge while its end moves by a pixel.
export const fadesBelow = (following: boolean, below: number) => !following && below > FOLLOW_BOTTOM_DEADBAND_PX;

/** Follow intent has a deadband; the final landing must use the actual rounded DOM end.
 * `fallbackEnd` keeps DOM-free transcript tests and a pre-layout browser pass deterministic; a
 * nonzero scrollHeight always wins once the scroller has painted its content. `exact: false` keeps
 * the streaming follow deadband so a late row measurement does not put its bottom under the dock. */
export function settleFollowBottom(
  node: Pick<HTMLElement, "scrollTop" | "scrollHeight" | "clientHeight">,
  fallbackEnd = 0,
  exact = true,
): boolean {
  const domEnd = node.scrollHeight - node.clientHeight;
  const end = Math.max(0, node.scrollHeight > 0 ? domEnd : fallbackEnd);
  if (end === node.scrollTop || (!exact && Math.abs(end - node.scrollTop) <= FOLLOW_BOTTOM_DEADBAND_PX)) return false;
  node.scrollTop = end;
  return true;
}

// Geometry only: importing the transcript model here would also initialize its markdown/font
// measurement dependencies. Zero-height bookkeeping rows are skipped as in layout.
function firstVisible(layout: GeometrySource, top: number): number {
  return Math.max(0, geometryOf(layout).upperBoundTop(Math.max(0, top)) - 1);
}

// A prepend moves old rows by the count added; a stream keeps their indices. Check both in O(1),
// then a bounded neighborhood for an update that changed both ends in the same commit.
function movedIndex(
  rows: readonly Pick<AcpmuxRow, "id">[],
  id: string,
  at: number,
  shift: number,
  indexById?: Map<string, number>,
): number {
  if (rows[at]?.id === id) return at;
  if (rows[at + shift]?.id === id) return at + shift;
  for (let delta = 1; delta <= 32; delta++) {
    for (const index of [at - delta, at + delta, at + shift - delta, at + shift + delta])
      if (rows[index]?.id === id) return index;
  }
  return indexById?.get(id) ?? -1;
}

/** The offset to correct from for one placement pass. */
export function scrollAnchorBase(liveTop: number, acknowledgedTop: number, readerLeft: boolean): number {
  return readerLeft ? liveTop : acknowledgedTop;
}

/**
 * Resolve the scroll offset that keeps the first visible row at the same viewport
 * position after a transcript placement pass.
 *
 * The caller supplies the offset it wants to anchor from. In particular, a
 * browser can have already applied its own scroll adjustment while a row grows;
 * using that live value as the base would apply the adjustment twice. The
 * caller should use its last reader offset for layout-only commits and the live
 * offset only after a real reader input.
 */
export function preserveScrollAnchorTop({
  oldLayout,
  newLayout,
  oldRows,
  newRows,
  liveTop,
  anchorTop,
  folds,
}: {
  oldLayout: GeometrySource;
  newLayout: GeometrySource;
  oldRows: readonly Pick<AcpmuxRow, "id">[];
  newRows: readonly Pick<AcpmuxRow, "id">[];
  liveTop: number;
  anchorTop: number;
  /// The folds a ride showed (conversation/foldRide.ts): each folding row's old index and how far its
  /// height was from its old one. The rows under a fold already show that much below their old tops,
  /// mounted or not, so the placement moves them that much less.
  folds?: readonly { index: number; delta: number }[];
}): number | undefined {
  const oldGeometry = geometryOf(oldLayout);
  const newGeometry = geometryOf(newLayout);
  let first = firstVisible(oldLayout, liveTop);
  const sorted = folds?.length ? [...folds].sort((a, b) => a.index - b.index) : [];
  const shown = (at: number) => sorted.reduce((sum, fold) => (fold.index < at ? sum + fold.delta : sum), 0);
  // Rows under a fold show away from their old tops: the row at the view's top is the one shown
  // there, which may be the folding row itself (an open, however far into its body) or a row below
  // (a close). Between two folds every row shows by one shift, so each run is one lookup: O(folds)
  // lookups, whatever the fold's size or the rows mounted (review of #39917 at 4d8ff5ab: "corrects
  // scrollTop 3900 to 7900, although 3900 remains inside the prompt").
  for (let k = 0, shift = 0, start = 0; k <= sorted.length; k += 1) {
    const fold = sorted[k];
    const end = fold ? fold.index : oldGeometry.count - 1;
    const at = firstVisible(oldLayout, liveTop - shift);
    // Above this run's first row as shown: in the folding row that ends the run before it.
    if (at < start) {
      first = start - 1;
      break;
    }
    // The folding row, unless a close shows the row after it at the view's top already.
    const passed =
      fold && at === end && end + 1 < oldGeometry.count && oldGeometry.topAt(end + 1) + shift + fold.delta <= liveTop;
    if (at <= end && !passed) {
      first = at;
      break;
    }
    if (!fold) break;
    shift += fold.delta;
    start = end + 1;
  }
  // A row's own resize must not move its top edge. The first visible row is
  // therefore the anchor; rows below it are irrelevant to this correction. A simple prepend or
  // stream resolves in constant time. Build an id index only after that fast path misses, which
  // handles a mixed prepend/removal without making normal token updates scan every row.
  let indexById: Map<string, number> | undefined;
  for (let oldIndex = first; oldIndex < Math.min(oldRows.length, first + 32); oldIndex += 1) {
    const id = oldRows[oldIndex]?.id;
    if (!id) continue;
    let newIndex = movedIndex(newRows, id, oldIndex, newRows.length - oldRows.length);
    if (newIndex < 0) {
      indexById ??= new Map(newRows.map((row, index) => [row.id, index]));
      newIndex = movedIndex(newRows, id, oldIndex, newRows.length - oldRows.length, indexById);
    }
    if (newIndex < 0) continue;
    return anchorTop + newGeometry.topAt(newIndex) - oldGeometry.topAt(oldIndex) - shown(oldIndex);
  }
  return undefined;
}
