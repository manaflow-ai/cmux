/// The least height a list row draws at, in px: the rows a window can show are its height over this.
export const ROW_MIN_PX = 24;
/// The rows mounted past each edge of the view, in viewports (a list may declare up to the most).
export const OVERSCAN_VIEWS = 1;
export const MAX_OVERSCAN_VIEWS = 2;

/// The rows mounted past the view's edge from a list's open until its first scroll.
export const FIRST_PAINT_OVERSCAN_ROWS = 8;

/// The rows a list mounts at its open, for a window `viewHeight` px tall: as many as can show and
/// FIRST_PAINT_OVERSCAN_ROWS under them (a list opens at its top).
export function firstRowCount(viewHeight: number): number {
  return Math.max(1, Math.ceil(viewHeight / ROW_MIN_PX)) + FIRST_PAINT_OVERSCAN_ROWS;
}
