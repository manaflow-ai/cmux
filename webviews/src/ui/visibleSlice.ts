// The visible slice: the part of a page in sight when the host, not the page, scrolls it. A page as tall
// as its content (the sidebar chats blocks, an app panel's scene) never sees its own scroll, so the host
// streams `{revision, top, height}` in CSS px from the page's top (`height` 0: scrolled out). A list on
// such a page mounts only the items that meet the band around it, one slice height each side
// (`sliceBand`), between spacers that keep the page's height; before the first slice it draws whole.
// The streams that carry it share this shape: `cmux.sidebarChats.slice` (pages/sidebar-chats/model.ts)
// and `cmux.apps.panels.slice` (apps/scene/panelsClient.ts).

/** The visible part of a page, in CSS px from its top. `revision` orders slices (the page's own drawn
 * revision where it has one). */
export interface VisibleSlice {
  revision: number;
  top: number;
  height: number;
}

/** A slice event from the host, checked: anything that is not one (a missing or non-finite field, a
 * negative height) is dropped. */
export function parseVisibleSlice(data: unknown): VisibleSlice | null {
  if (!data || typeof data !== "object") return null;
  const { revision, top, height } = data as Record<string, unknown>;
  const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
  if (!finite(revision) || !finite(top) || !finite(height) || height < 0) return null;
  return { revision, top, height };
}

/** The band a slice mounts, `[top - height, top + 2 * height]` (one slice height of overscan each side),
 * in the coordinates of a list that starts `origin` px below the page's top. Null when nothing is in
 * sight (`height` 0). */
export function sliceBand(slice: VisibleSlice, origin = 0): { low: number; high: number } | null {
  if (slice.height <= 0) return null;
  return { low: slice.top - slice.height - origin, high: slice.top + 2 * slice.height - origin };
}

export interface ItemRange {
  start: number;
  end: number;
}

/** The items `[start, end)` of `count` items each `stride` px apart from 0 that meet `[low, high]`: item i
 * spans `[i * stride, (i + 1) * stride)` and meets it when it starts before `high` and ends after `low`. */
export function strideRange(count: number, stride: number, { low, high }: { low: number; high: number }): ItemRange {
  if (count <= 0) return { start: 0, end: 0 };
  if (!(stride > 0)) return { start: 0, end: count };
  const start = Math.min(count, Math.max(0, Math.floor(low / stride)));
  const end = Math.min(count, Math.max(start, Math.ceil(high / stride)));
  return { start, end };
}

/** The same for items of any size laid out top to bottom (`startOf` and `endOf` never decrease with the
 * index), by binary search: the first item that ends after `low`, up to the first that starts at or after
 * `high`. */
export function offsetRange(
  count: number,
  startOf: (index: number) => number,
  endOf: (index: number) => number,
  { low, high }: { low: number; high: number },
): ItemRange {
  const first = (test: (index: number) => boolean) => {
    let lo = 0;
    let hi = count;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (test(mid)) hi = mid;
      else lo = mid + 1;
    }
    return lo;
  };
  const start = first((index) => endOf(index) > low);
  const end = Math.max(
    start,
    first((index) => startOf(index) >= high),
  );
  return { start, end };
}
