/// The least height a list row draws at, in px: the rows a window can show are its height over this.
const ROW_MIN_PX = 24;
/// Rows drawn past the window's edge, so a slow scroll finds them there.
export const OVERSCAN_ROWS = 8;

/// The rows an open draws for a window `viewHeight` px tall: as many as can show, and the overscan.
export function firstRowCount(viewHeight: number): number {
  return Math.max(1, Math.ceil(viewHeight / ROW_MIN_PX)) + OVERSCAN_ROWS;
}
