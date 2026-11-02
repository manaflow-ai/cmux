/**
 * The composer slash list has fixed 31px rows (styles.css) in a menu capped at 296px.
 * Keep keyboard selection in the complete match list; mount only this window of rows.
 * The same logical indices can also feed a future native-popup consumer.
 */
export const SLASH_ROW_PX = 31;
export const SLASH_MAX_VIEWPORT_PX = 296;
export const SLASH_OVERSCAN_ROWS = 6;

export type SlashViewport = {
  start: number;
  end: number;
  firstVisible: number;
  afterVisible: number;
  scrollTop: number;
  topSpace: number;
  bottomSpace: number;
};

const finite = (value: number, fallback: number) => (Number.isFinite(value) ? value : fallback);
const clamp = (value: number, low: number, high: number) => Math.max(low, Math.min(high, value));

export function slashViewport(
  total: number,
  scrollTop = 0,
  viewportPx = SLASH_MAX_VIEWPORT_PX,
  rowPx = SLASH_ROW_PX,
  overscan = SLASH_OVERSCAN_ROWS,
): SlashViewport {
  total = Math.max(0, Math.trunc(finite(total, 0)));
  viewportPx = Math.max(1, finite(viewportPx, SLASH_MAX_VIEWPORT_PX));
  rowPx = Math.max(1, finite(rowPx, SLASH_ROW_PX));
  overscan = Math.max(0, Math.trunc(finite(overscan, SLASH_OVERSCAN_ROWS)));
  const top = clamp(finite(scrollTop, 0), 0, Math.max(0, total * rowPx - viewportPx));
  const firstVisible = Math.min(total, Math.floor(top / rowPx));
  const afterVisible = Math.min(total, Math.ceil((top + viewportPx) / rowPx));
  const start = Math.max(0, firstVisible - overscan);
  const end = Math.min(total, afterVisible + overscan);
  return {
    start,
    end,
    firstVisible,
    afterVisible,
    scrollTop: top,
    topSpace: start * rowPx,
    bottomSpace: (total - end) * rowPx,
  };
}

/** Compute the smallest scroll adjustment that reveals the selected logical row. */
export function slashScrollForActive(
  active: number,
  total: number,
  scrollTop: number,
  viewportPx = SLASH_MAX_VIEWPORT_PX,
  rowPx = SLASH_ROW_PX,
): number {
  if (total <= 0) return 0;
  rowPx = Math.max(1, finite(rowPx, SLASH_ROW_PX));
  viewportPx = Math.max(1, finite(viewportPx, SLASH_MAX_VIEWPORT_PX));
  const chosen = clamp(active, 0, total - 1);
  const maxTop = Math.max(0, total * rowPx - viewportPx);
  const at = clamp(finite(scrollTop, 0), 0, maxTop);
  const start = chosen * rowPx;
  const end = start + rowPx;
  const next = start < at ? start : end > at + viewportPx ? end - viewportPx : at;
  return clamp(next, 0, maxTop);
}

/** When a wheel/scrollbar jump leaves the selection offscreen, follow the first visible row. */
export function slashActiveAfterScroll(active: number, total: number, view: SlashViewport): number {
  if (total <= 0) return 0;
  if (active < view.firstVisible || active >= view.afterVisible) return Math.min(total - 1, view.firstVisible);
  return clamp(active, 0, total - 1);
}
