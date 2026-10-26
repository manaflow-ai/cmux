import type { AcpmuxRow, ConversationLayout } from "../model";

/** Follow intent has a deadband; the final landing must use the actual rounded DOM end. */
export function settleFollowBottom(node: Pick<HTMLElement, "scrollTop" | "scrollHeight" | "clientHeight">): boolean {
  const end = Math.max(0, node.scrollHeight - node.clientHeight);
  if (end === node.scrollTop) return false;
  node.scrollTop = end;
  return true;
}

// Binary search only geometry; importing the transcript model here would also initialize its
// markdown/font measurement dependencies. Zero-height bookkeeping rows are skipped as in layout.
function firstVisible(tops: Float64Array, top: number): number {
  let low = 0;
  let high = tops.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (tops[middle]! <= Math.max(0, top)) low = middle + 1;
    else high = middle;
  }
  return Math.max(0, low - 1);
}

// A prepend moves old rows by the count added; a stream keeps their indices. Check both in O(1),
// then a bounded neighborhood for an update that changed both ends in the same commit.
function movedIndex(rows: readonly Pick<AcpmuxRow, "id">[], id: string, at: number, shift: number): number {
  if (rows[at]?.id === id) return at;
  if (rows[at + shift]?.id === id) return at + shift;
  for (let delta = 1; delta <= 32; delta++) {
    for (const index of [at - delta, at + delta, at + shift - delta, at + shift + delta])
      if (rows[index]?.id === id) return index;
  }
  return -1;
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
}: {
  oldLayout: ConversationLayout;
  newLayout: ConversationLayout;
  oldRows: readonly Pick<AcpmuxRow, "id">[];
  newRows: readonly Pick<AcpmuxRow, "id">[];
  liveTop: number;
  anchorTop: number;
}): number | undefined {
  const first = firstVisible(oldLayout.tops, liveTop);
  // A row's own resize must not move its top edge. The first visible row is
  // therefore the anchor; rows below it are irrelevant to this correction.
  for (let oldIndex = first; oldIndex < Math.min(oldRows.length, first + 32); oldIndex += 1) {
    const id = oldRows[oldIndex]?.id;
    if (!id) continue;
    const newIndex = movedIndex(newRows, id, oldIndex, newRows.length - oldRows.length);
    if (newIndex < 0) continue;
    return anchorTop + newLayout.tops[newIndex]! - oldLayout.tops[oldIndex]!;
  }
  return undefined;
}
