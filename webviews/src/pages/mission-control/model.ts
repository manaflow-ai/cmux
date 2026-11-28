// Mission control (wow-20 idea 8): every session on every machine as a live thumbnail in one grid,
// each badged working, waiting on you or done. The grid draws only the tiles in sight, plus one
// viewport of rows each side, so 200 sessions mount the same tiles as 20 (`visibleRange`).
//
// First slice: the grid itself, over tiles the host sends. Nothing opens it yet (no route, no
// keystroke); the host feed (session list + last-known snapshot per session) is the follow-up issue.

/** What a tile shows: the session's own surface. */
export type MissionTileKind = "terminal" | "browser" | "chat";

/** The badge: working (spinner), waiting on the person, or done. */
export type MissionTileState = "working" | "waiting" | "done";

/** A tile's last-known picture: an image URL (blob:, data:) and its pixel size. */
export interface MissionThumb {
  src: string;
  width: number;
  height: number;
}

/** One session's tile. `age` is formatted by the host ("2m"). */
export interface MissionTile {
  id: string;
  title: string;
  machineName: string;
  kind: MissionTileKind;
  state: MissionTileState;
  age?: string | null;
  thumb?: MissionThumb | null;
}

/** The grid's geometry in CSS px. */
export interface MissionGridMetrics {
  /** The narrowest a tile may be; columns are as many as fit. */
  minTileWidth: number;
  /** The thumbnail's height over its width (16:10 is 0.625). */
  aspect: number;
  /** The caption under the thumbnail. */
  caption: number;
  gap: number;
}

export const DEFAULT_METRICS: MissionGridMetrics = { minTileWidth: 240, aspect: 0.625, caption: 40, gap: 16 };

export interface MissionGridLayout {
  columns: number;
  tileWidth: number;
  tileHeight: number;
  /** One row's stride (tile plus gap). */
  stride: number;
  /** The whole grid's height, so the scroll bar is true while only some tiles mount. */
  height: number;
}

/** Columns and tile size for `count` tiles in `width` CSS px. */
export function gridLayout(count: number, width: number, metrics: MissionGridMetrics = DEFAULT_METRICS): MissionGridLayout {
  const { minTileWidth, aspect, caption, gap } = metrics;
  const inner = Math.max(0, width);
  const columns = Math.max(1, Math.floor((inner + gap) / (minTileWidth + gap)));
  const tileWidth = Math.max(0, (inner - gap * (columns - 1)) / columns);
  const tileHeight = Math.round(tileWidth * aspect) + caption;
  const stride = tileHeight + gap;
  const rows = Math.ceil(count / columns);
  const height = rows > 0 ? rows * stride - gap : 0;
  return { columns, tileWidth, tileHeight, stride, height };
}

/** The tiles to mount, `[start, end)`: the rows meeting the viewport `[top, top + height)` and one
 * viewport each side. The count depends on the viewport and the layout only, never on `count` past
 * what fits, which is what keeps 200 sessions as cheap as 20. */
export function visibleRange(
  count: number,
  layout: MissionGridLayout,
  viewport: { top: number; height: number },
): { start: number; end: number } {
  if (count <= 0 || viewport.height <= 0 || !(layout.stride > 0)) return { start: 0, end: 0 };
  const low = viewport.top - viewport.height;
  const high = viewport.top + 2 * viewport.height;
  const firstRow = Math.max(0, Math.floor(low / layout.stride));
  const lastRow = Math.max(firstRow, Math.ceil(high / layout.stride));
  const start = Math.min(count, firstRow * layout.columns);
  const end = Math.min(count, lastRow * layout.columns);
  return { start, end };
}

/** How many tiles want the person, for the header ("3 waiting on you"). */
export function countByState(tiles: readonly MissionTile[]): Record<MissionTileState, number> {
  const counts: Record<MissionTileState, number> = { working: 0, waiting: 0, done: 0 };
  for (const tile of tiles) counts[tile.state] += 1;
  return counts;
}
