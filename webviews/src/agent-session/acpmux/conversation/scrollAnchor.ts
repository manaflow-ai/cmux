import type { AcpmuxRow, ConversationLayout } from "../model";
import { visibleLayoutRange } from "../model";

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
  const first = visibleLayoutRange(oldLayout, liveTop, 0, 0).first;
  // A row's own resize must not move its top edge. The first visible row is
  // therefore the anchor; rows below it are irrelevant to this correction.
  for (let oldIndex = first; oldIndex < Math.min(oldRows.length, first + 32); oldIndex += 1) {
    const id = oldRows[oldIndex]?.id;
    if (!id) continue;
    // Streaming revisions preserve the row's index. Avoid a transcript-wide
    // scan on every token; the fallback is only for an insertion/removal.
    const newIndex = newRows[oldIndex]?.id === id ? oldIndex : newRows.findIndex((row) => row.id === id);
    if (newIndex < 0) continue;
    return anchorTop + newLayout.tops[newIndex]! - oldLayout.tops[oldIndex]!;
  }
  return undefined;
}
