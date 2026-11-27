// The timeline's virtual window, written for the React Compiler: only rows near the viewport are
// rendered, at offsets computed in render from two pure inputs, the rows and a metrics snapshot
// (measured row heights, scroll position, viewport height). The snapshot lives in a small external
// store (useSyncExternalStore) that the scroll handler and one ResizeObserver update, so render
// never reads a ref and nothing a memoized child receives is mutated in place.
//
// Scroll position has one narrow layout effect: a conversation opens at its newest message; while
// the reader is at the bottom it follows new content (a new message, a growing draft); otherwise
// the row at the top of the viewport keeps its place when rows above it change height or older
// messages are prepended. A `focus` row (a message a link opened) is scrolled to the middle once,
// after layout, and the reader stops following the bottom.
import { useLayoutEffect, useRef, useState, useSyncExternalStore, type RefObject } from "react";

const NEAR_BOTTOM_PX = 48;
const OVERSCAN_PX = 800;
const LOAD_OLDER_PX = 200;

interface Metrics {
  heights: ReadonlyMap<string, number>;
  scrollTop: number;
  viewport: number;
}

class TimelineMetrics {
  private snapshot: Metrics = { heights: new Map(), scrollTop: 0, viewport: 1200 };
  private readonly listeners = new Set<() => void>();
  private observer?: ResizeObserver;

  getSnapshot = (): Metrics => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** Reads the scroller's position (a scroll event, or after the effect moved it). */
  readScroll(element: HTMLElement): void {
    const { scrollTop, clientHeight } = element;
    // A hidden scroller has no height: keep the last viewport, and publish only a real change.
    const viewport = clientHeight || this.snapshot.viewport;
    if (scrollTop === this.snapshot.scrollTop && viewport === this.snapshot.viewport) return;
    this.publish({ ...this.snapshot, scrollTop, viewport });
  }

  /** Another conversation: the old rows' heights are dropped (rows re-measure as they render). */
  reset(): void {
    if (this.snapshot.heights.size === 0) return;
    this.publish({ ...this.snapshot, heights: new Map() });
  }

  /** A row's ref: its height is measured now and whenever it changes. */
  observe = (element: HTMLElement | null): (() => void) | undefined => {
    if (!element) return undefined;
    this.observer ??= new ResizeObserver((entries) => {
      const heights = new Map(this.snapshot.heights);
      let changed = false;
      for (const entry of entries) {
        const key = (entry.target as HTMLElement).dataset.key;
        const height = entry.borderBoxSize[0]?.blockSize ?? entry.contentRect.height;
        if (key && heights.get(key) !== height) {
          heights.set(key, height);
          changed = true;
        }
      }
      if (changed) this.publish({ ...this.snapshot, heights });
    });
    this.observer.observe(element);
    const observer = this.observer;
    return () => observer.unobserve(element);
  };

  private publish(next: Metrics): void {
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
}

export interface WindowRow {
  key: string;
  estimate: number;
}

export interface WindowItem {
  index: number;
  key: string;
  start: number;
}

export interface TimelineWindow {
  items: WindowItem[];
  total: number;
  /** The scroller's ref. */
  scroller: RefObject<HTMLDivElement | null>;
  /** Each rendered row's ref (the row element carries `data-key`). */
  measure: (element: HTMLElement | null) => (() => void) | undefined;
  /** The scroller's scroll handler; true when the reader reached the top (load older). */
  onScroll(): boolean;
}

/** Row offsets: every row's start, and the total height. */
function layout(rows: readonly WindowRow[], heights: ReadonlyMap<string, number>) {
  const starts: number[] = [];
  let total = 0;
  for (let index = 0; index < rows.length; index += 1) {
    starts[index] = total;
    total += heights.get(rows[index]!.key) ?? rows[index]!.estimate;
  }
  return { starts, total };
}

export function useTimelineWindow(
  rows: readonly WindowRow[],
  conversation: string | undefined,
  focus?: string,
): TimelineWindow {
  const [metrics] = useState(() => new TimelineMetrics());
  const snapshot = useSyncExternalStore(metrics.subscribe, metrics.getSnapshot);
  const scroller = useRef<HTMLDivElement | null>(null);
  const { starts, total } = layout(rows, snapshot.heights);
  const from = snapshot.scrollTop - OVERSCAN_PX;
  const to = snapshot.scrollTop + snapshot.viewport + OVERSCAN_PX;
  const items: WindowItem[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const start = starts[index]!;
    const end = index + 1 < rows.length ? starts[index + 1]! : total;
    if (end < from) continue;
    if (start > to) break;
    items.push({ index, key: rows[index]!.key, start });
  }

  // What the scroll effect remembers between renders (written only in the effect and the handler).
  const memory = useRef({
    conversation: undefined as string | undefined,
    atBottom: true,
    anchor: undefined as { key: string; offset: number } | undefined,
    focused: undefined as string | undefined,
  });
  const anchorFor = (element: HTMLElement) => {
    const top = element.scrollTop;
    const index = starts.findIndex((start, i) => (i + 1 < starts.length ? starts[i + 1]! : total) > top);
    const row = index >= 0 ? rows[index] : undefined;
    return row ? { key: row.key, offset: top - starts[index]! } : undefined;
  };

  useLayoutEffect(() => {
    const element = scroller.current;
    const state = memory.current;
    if (!element) return;
    if (conversation !== state.conversation) {
      const first = state.conversation === undefined;
      state.conversation = conversation;
      state.atBottom = true;
      // The new rows re-render from estimates and re-measure; this effect runs again after that.
      if (!first) metrics.reset();
    }
    const focusIndex = focus && focus !== state.focused ? rows.findIndex((row) => row.key === focus) : -1;
    if (focusIndex >= 0) {
      // Once per focus: the row's middle at the viewport's middle; then the anchor keeps it there.
      state.focused = focus;
      state.atBottom = false;
      const end = focusIndex + 1 < rows.length ? starts[focusIndex + 1]! : total;
      element.scrollTop = Math.max(0, (starts[focusIndex]! + end - element.clientHeight) / 2);
    } else if (state.atBottom) {
      element.scrollTop = element.scrollHeight;
    } else if (state.anchor) {
      const index = rows.findIndex((row) => row.key === state.anchor!.key);
      if (index >= 0) {
        const wanted = starts[index]! + state.anchor.offset;
        if (Math.abs(element.scrollTop - wanted) >= 1) element.scrollTop = wanted;
      }
    }
    state.anchor = anchorFor(element);
    // Sync, before paint: the window renders the rows at the new position in the same frame.
    metrics.readScroll(element);
  });

  return {
    items,
    total,
    scroller,
    measure: metrics.observe,
    onScroll() {
      const element = scroller.current;
      if (!element) return false;
      const state = memory.current;
      state.atBottom = element.scrollHeight - element.scrollTop - element.clientHeight < NEAR_BOTTOM_PX;
      state.anchor = anchorFor(element);
      metrics.readScroll(element);
      return element.scrollTop < LOAD_OLDER_PX;
    },
  };
}
