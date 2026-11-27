// The visible slice: the part of a page in sight when the host, not the page, scrolls it. A page as tall
// as its content (an app panel's scene) never sees its own scroll, so the host streams one slice per frame
// at most on `VISIBLE_SLICE_OP`. A list on such a page mounts only the items that meet the band around it,
// one slice height each side (`sliceBand`), between spacers that keep the page's height; before the
// first slice for the drawn content it draws whole. Every host-scrolled list uses this one stream.
//
// The sidebar chats blocks still have their own `cmux.sidebarChats.slice` and their own copy of the parse
// and range math (pages/sidebar-chats/model.ts `parseSlice`, `sliceRange`): dedupe them into this module
// when the sidebar moves to the generic stream.

/** Stream, host to page, subscribed with `{surface}`: `{surface, revision, top, height}` in CSS px, the
 * part of `surface`'s content in sight, from its top (`height` 0: scrolled out). `surface` names what the
 * page drew (an app panel's mount id); `revision` is the content revision the slice was measured against.
 * The page drops an event for another surface, and applies a slice only to the content revision it names. */
export const VISIBLE_SLICE_OP = "cmux.page.visibleSlice";

/** The visible part of a surface's content, in CSS px from its top, for content `revision`. */
export interface VisibleSlice {
  revision: number;
  top: number;
  height: number;
}

/** A `VISIBLE_SLICE_OP` event, checked: one for another surface (or none), with a missing or non-finite
 * field, or a negative height, is dropped. */
export function parseVisibleSlice(data: unknown, surface: string): VisibleSlice | null {
  if (!data || typeof data !== "object") return null;
  const event = data as Record<string, unknown>;
  if (typeof event.surface !== "string" || event.surface !== surface) return null;
  const { revision, top, height } = event;
  const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
  if (!finite(revision) || !finite(top) || !finite(height) || height < 0) return null;
  return { revision, top, height };
}

/** One surface's slice, bound to the content revision drawn (for `useSyncExternalStore`). The drawn
 * revision is the one the host gave the content last drawn, never counted here. A slice applies only to the
 * revision it names: one for the drawn revision shows at once; one for a revision not drawn yet (it raced
 * the content) waits and shows only if exactly that revision is drawn; any other is dropped, so a gap in
 * the content's revisions never puts an old slice on newer content. Content without a revision
 * (`setDrawn(null)`: an old host) takes no slice. A shown slice holds until the host's next one. */
export class VisibleSliceInput {
  private drawn: number | null = null;
  private slice: VisibleSlice | null = null;
  private pending: VisibleSlice | null = null;
  private readonly listeners = new Set<() => void>();

  get = (): VisibleSlice | null => this.slice;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** The revision of the content now drawn, or null for content without one. */
  setDrawn(revision: number | null): void {
    this.drawn = revision;
    if (revision === null) {
      // No slice applies to unrevisioned content: what was shown no longer does either.
      this.pending = null;
      this.publish(null);
      return;
    }
    const pending = this.pending;
    if (pending && pending.revision <= revision) {
      this.pending = null;
      if (pending.revision === revision) this.publish(pending);
    }
  }

  /** A parsed slice from the host. */
  show(next: VisibleSlice): void {
    if (this.drawn !== null && next.revision === this.drawn) this.publish(next);
    else if (this.drawn === null || next.revision > this.drawn) {
      if (!this.pending || next.revision >= this.pending.revision) this.pending = next;
    }
  }

  private publish(next: VisibleSlice | null): void {
    const last = this.slice;
    if (last === next) return;
    if (last && next && last.revision === next.revision && last.top === next.top && last.height === next.height) return;
    this.slice = next;
    for (const listener of this.listeners) listener();
  }
}

/** The band a slice mounts, `[top - height, top + 2 * height]` (one slice height of overscan each side),
 * in the coordinates of a list that starts `origin` px below the content's top. Null when nothing is in
 * sight (`height` 0). */
export function sliceBand(slice: VisibleSlice, origin = 0): { low: number; high: number } | null {
  if (slice.height <= 0) return null;
  return { low: slice.top - slice.height - origin, high: slice.top + 2 * slice.height - origin };
}

/** The items `[start, end)` of `count` items laid out top to bottom (`startOf` and `endOf` never decrease
 * with the index) that meet `[low, high]`, by binary search: the first item that ends after `low`, up to
 * the first that starts at or after `high`. */
export function offsetRange(
  count: number,
  startOf: (index: number) => number,
  endOf: (index: number) => number,
  { low, high }: { low: number; high: number },
): { start: number; end: number } {
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
