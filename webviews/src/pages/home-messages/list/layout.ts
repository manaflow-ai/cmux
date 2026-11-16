// The list's geometry, ported from the native list (MessagesLab's `SidebarMetrics`, the Home
// header's `HomeSidebarHeaderLayout` and `HomeSidebarWidth`). Pure numbers in CSS pixels (points).

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const ZERO: Rect = { x: 0, y: 0, width: 0, height: 0 };

/** The column's width: the avatar-only minimum, the width it starts at, and the transcript's least
 * room beside it (about 30 characters of a bubble). */
export const WIDTH = { minimum: 76, standard: 320, transcriptMinimum: 280, divider: 1 } as const;

/** `width` kept between the minimum and the smaller of half the page and what leaves the transcript
 * its minimum (a page too narrow for both keeps the list's minimum). */
export function clampWidth(width: number, page: number): number {
  return Math.max(WIDTH.minimum, Math.min(width, page / 2, page - WIDTH.transcriptMinimum));
}

/** Below this the list is avatar-only: one column of big avatars with the name under each. */
export const COMPACT_BELOW = 180;

export const ROW = {
  height: 72,
  selectionInsetX: 10,
  avatar: 40,
  avatarX: 28,
  textX: 80,
  textRightInset: 20,
  dotCenterX: 19,
  dot: 10,
} as const;

export const PIN = {
  columns: 3,
  insetX: 10,
  minTileWidth: 80,
  minAvatar: 52,
  maxAvatar: 76,
  avatarSideInset: 14,
  topPad: 12,
  nameGap: 6,
  nameHeight: 16,
  bottomPad: 8,
  sectionBottom: 6,
  compactMaxAvatar: 56,
  compactSideInset: 12,
} as const;

/** The list's metrics at one width (MessagesLab's `SidebarMetrics`). */
export function listMetrics(width: number) {
  const compact = width < COMPACT_BELOW;
  const columns = compact
    ? 1
    : Math.max(1, Math.min(PIN.columns, Math.floor((width - 2 * PIN.insetX) / PIN.minTileWidth) || 1));
  const tileWidth = Math.floor((width - 2 * PIN.insetX) / columns);
  const compactAvatar = Math.min(
    PIN.compactMaxAvatar,
    Math.max(ROW.avatar, Math.floor(width - 2 * PIN.compactSideInset)),
  );
  const fit = Math.round(tileWidth - 2 * PIN.avatarSideInset);
  const pinAvatar = compact
    ? compactAvatar
    : columns === PIN.columns
      ? Math.min(PIN.maxAvatar, Math.max(PIN.minAvatar, fit))
      : PIN.minAvatar;
  const tileHeight = PIN.topPad + pinAvatar + PIN.nameGap + PIN.nameHeight + PIN.bottomPad;
  const rowHeight = compact ? tileHeight : ROW.height;
  const pinnedHeight = (count: number) =>
    count > 0 ? Math.ceil(count / columns) * tileHeight + (compact ? 0 : PIN.sectionBottom) : 0;
  const tileRect = (index: number): Rect => {
    const r = Math.floor(index / columns);
    const c = index % columns;
    const x0 = Math.round((width - tileWidth * columns) / 2);
    return { x: x0 + c * tileWidth, y: r * tileHeight, width: tileWidth, height: tileHeight };
  };
  /** The grid index under a point in the grid's coordinates (clamped to `count`). */
  const tileIndexAt = (x: number, y: number, count: number): number => {
    const x0 = Math.round((width - tileWidth * columns) / 2);
    const c = Math.min(columns - 1, Math.max(0, Math.floor((x - x0) / tileWidth)));
    const r = Math.max(0, Math.floor(y / tileHeight));
    return Math.min(count, r * columns + c);
  };
  return {
    width,
    compact,
    columns,
    tileWidth,
    pinAvatar,
    compactAvatar,
    tileHeight,
    rowHeight,
    pinnedHeight,
    tileRect,
    tileIndexAt,
  };
}

export type ListMetrics = ReturnType<typeof listMetrics>;

/** The header's sizes (the native Compact density with the default text). */
export const HEADER = {
  band: 52,
  topMargin: 1,
  inset: 10,
  gap: 6,
  minimumField: 72,
  edge: 4,
  rowGap: 10,
  side: 30,
  chipHeight: 24,
  chipGap: 6,
} as const;

export interface HeaderLayout {
  compact: boolean;
  /** The search capsule; zero-sized in the avatar-only list while the search is closed. */
  search: Rect;
  /** The avatar-only list's search circle while the search is closed. */
  searchIcon: Rect;
  /** The Unread toggle; zero-sized only while an open search covers the avatar-only band. */
  filter: Rect;
  buttonsCovered: boolean;
  /** The on filter's chip row (Unread ×), zero-sized while no filter is on. */
  filterChip: Rect;
  /** Where the list starts. */
  listTop: number;
}

/** The header row: search and the Unread toggle in a band as tall as the transcript's header. Under
 * the window's traffic lights (`windowControls`, in the list's coordinates: the host's value) the
 * lights get the top row, the Unread toggle at its right end on their line, and the search field
 * spans the row under them. The avatar-only list shows search as a circle beside the toggle. */
export function headerLayout(
  width: number,
  searchOpen: boolean,
  windowControls: Rect | null,
  filterOn: boolean,
): HeaderLayout {
  const base = headerRow(Math.max(0, width), searchOpen, windowControls);
  if (!filterOn || base.buttonsCovered) return base;
  const inset = base.compact ? HEADER.edge : HEADER.inset;
  const filterChip = { x: inset, y: base.listTop, width: Math.max(0, width - 2 * inset), height: HEADER.chipHeight };
  return { ...base, filterChip, listTop: filterChip.y + filterChip.height + HEADER.chipGap };
}

function headerRow(width: number, searchOpen: boolean, controls: Rect | null): HeaderLayout {
  const side = HEADER.side;
  const y = Math.round((HEADER.band - side) / 2);
  const compact = width < COMPACT_BELOW;
  const underLights = controls ? Math.ceil(controls.y + controls.height + HEADER.rowGap) : null;
  const out: HeaderLayout = {
    compact,
    search: ZERO,
    searchIcon: ZERO,
    filter: ZERO,
    buttonsCovered: false,
    filterChip: ZERO,
    listTop: HEADER.band,
  };
  if (compact) {
    const rowY = underLights ?? y;
    if (searchOpen) {
      out.buttonsCovered = true;
      out.search = { x: HEADER.inset, y: rowY, width: Math.max(0, width - 2 * HEADER.inset), height: side };
      if (underLights !== null) out.listTop = Math.max(HEADER.band, out.search.y + side + HEADER.rowGap);
      return out;
    }
    out.search = { x: HEADER.inset, y, width: 0, height: 0 };
    const pair = 2 * side + HEADER.gap;
    if (width >= pair + 2 * HEADER.edge) {
      const x = Math.round((width - pair) / 2);
      out.searchIcon = { x, y: rowY, width: side, height: side };
      out.filter = { x: x + side + HEADER.gap, y: rowY, width: side, height: side };
    } else {
      out.filter = { x: Math.round((width - side) / 2), y: rowY, width: side, height: side };
    }
    if (underLights !== null) out.listTop = Math.max(HEADER.band, out.filter.y + side + HEADER.rowGap);
    return out;
  }
  if (controls && underLights !== null) {
    const filterX = width - HEADER.inset - side;
    if (filterX >= controls.x + controls.width + HEADER.gap) {
      const midY = controls.y + controls.height / 2;
      const d = Math.floor(Math.min(side, 2 * (midY - HEADER.topMargin)) / 2) * 2;
      out.filter = { x: width - HEADER.inset - d, y: Math.round(midY - d / 2), width: d, height: d };
      const rowY = Math.max(underLights, Math.ceil(out.filter.y + d + HEADER.rowGap));
      out.search = { x: HEADER.inset, y: rowY, width: Math.max(0, width - 2 * HEADER.inset), height: side };
    } else {
      const field = Math.max(HEADER.minimumField, width - 2 * HEADER.inset - (side + HEADER.gap));
      out.search = { x: HEADER.inset, y: underLights, width: field, height: side };
      out.filter = { x: HEADER.inset + field + HEADER.gap, y: underLights, width: side, height: side };
    }
    out.listTop = Math.max(HEADER.band, out.search.y + side + HEADER.rowGap);
    return out;
  }
  const field = Math.max(HEADER.minimumField, width - 2 * HEADER.inset - (side + HEADER.gap));
  out.search = { x: HEADER.inset, y, width: field, height: side };
  out.filter = { x: HEADER.inset + field + HEADER.gap, y, width: side, height: side };
  return out;
}
