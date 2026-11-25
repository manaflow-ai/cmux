import { visibleLayoutRange, layoutGeometry } from "../model";

/// Where a chat's transcript rests: the row at the top of the view and how far into it; null is the
/// latest message, which a reopened chat follows anyway.
export type ScrollAnchor = { rowId: string; offset: number };

/// Where a transcript scrolled to `top` rests: null at its latest message.
export function restingAnchor(
  top: number,
  atLatest: boolean,
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
): ScrollAnchor | null {
  const index = visibleLayoutRange(placed, top, 0, 0).first;
  const row = shown[index];
  return atLatest || !row ? null : { rowId: row.id, offset: top - layoutGeometry(placed).topAt(index) };
}

/// Where the warm rows are built from, as a row and how far into it: one string, so the deferred
/// render that builds them runs only when it moves. A row holds its content as rows page in above
/// it or a followed end moves under it; an offset into the whole stack did not, and a deferred one
/// from the frame before picked rows turns away (`warmTop`). The row's index is a hint for the read.
export function warmAnchor(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  at: number,
  step: number,
) {
  const index = visibleLayoutRange(placed, at, 0, 0).first;
  const row = shown[index];
  // In steps too: a row above that settles to its drawn height moves the row, not the anchor.
  return row ? `${Math.round((at - layoutGeometry(placed).topAt(index)) / step) * step}\n${index}\n${row.id}` : "";
}

/// The offset of `anchor` (warmAnchor) in `placed`: its row at the index it was found at, else looked
/// for (older history paged in above it, once, until the deferred anchor catches up). Undefined once
/// it is gone.
export function warmAnchorTop(
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
  anchor: string,
) {
  const [offset, hint, id] = anchor.split("\n");
  if (id === undefined) return undefined;
  const at = Number(hint);
  const index = shown[at]?.id === id ? at : shown.findIndex((row) => row.id === id);
  return index < 0 ? undefined : layoutGeometry(placed).topAt(index) + Number(offset);
}

/// Where a view whose reader's place is held (`heldPlace`) goes in this pass: the place itself once
/// its row is back among the rows (`found`); until then the oldest row held, where older pages come
/// in toward the reader's row, never the end. Undefined: nothing to place (no rows yet).
export function heldReaderPlace(
  place: ScrollAnchor,
  rows: readonly { id: string }[],
  placed: Parameters<typeof layoutGeometry>[0],
): { top: number; found?: true } | undefined {
  if (rows.length === 0) return undefined;
  const at = rows.findIndex((row) => row.id === place.rowId);
  const geometry = layoutGeometry(placed);
  return at >= 0 ? { top: geometry.topAt(at) + place.offset, found: true } : { top: geometry.topAt(0) };
}
