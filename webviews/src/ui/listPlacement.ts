/**
 * Where a list that stands beside a field's box (a composer's `/`, `@` or `:` list) opens, and how
 * tall it may grow there.
 *
 * Above the box when the whole list fits there, or when there is at least as much room above as
 * below (the chat's composer at the pane's foot); else below it (New Tab's box near the top of a
 * short window). The list then takes no more than the room on that side and scrolls inside it, so
 * it is never cut by the window's edge. Only when even the larger side has less than `floor` (a
 * few rows) does the list leave the page for the host's panel past the window's edge (`escapes`).
 */
export interface ListPlacement {
  side: "above" | "below";
  /** The height the list may take on `side`, in CSS pixels: the room less the gap and the margin. */
  room: number;
  /** Not even `floor` (or the whole list, when shorter) fits on the larger side. */
  escapes: boolean;
}

/** Between the list and its box. */
export const LIST_GAP_PX = 6;
/** Between the list and the window's edge. */
export const LIST_EDGE_PX = 8;
/** The least a list still reads at: three 28 px rows and the list's padding. */
export const LIST_FLOOR_PX = 96;

const finite = (value: number, fallback: number) => (Number.isFinite(value) ? value : fallback);

export function listPlacement(
  box: { top: number; bottom: number },
  viewportHeight: number,
  natural: number,
  {
    gap = LIST_GAP_PX,
    edge = LIST_EDGE_PX,
    floor = LIST_FLOOR_PX,
  }: { gap?: number; edge?: number; floor?: number } = {},
): ListPlacement {
  const above = Math.max(0, finite(box.top, 0) - gap - edge);
  const below = Math.max(0, finite(viewportHeight, 0) - finite(box.bottom, 0) - gap - edge);
  const want = Math.max(0, finite(natural, 0));
  const side = want <= above || above >= below ? "above" : "below";
  const room = Math.floor(side === "above" ? above : below);
  return { side, room, escapes: room < Math.min(want, floor) };
}
