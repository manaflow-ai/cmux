// A virtualized list over TanStack Virtual. Only the rows near the viewport are in the DOM, plus
// the active row (`activeIndex`), so `aria-activedescendant` never names a missing element, and the
// list scrolls to the active row (only if it is out of view) when it changes. Each row gets
// `aria-posinset`/`aria-setsize` from the caller's renderRow (it receives the index and the count).
import {
  isValidElement,
  useCallback,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type KeyboardEventHandler,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";

export interface VirtualListProps {
  count: number;
  /** Row height in pixels (rows may differ; this is the estimate before measuring). */
  estimateSize(index: number): number;
  /** The highlighted row: always rendered, scrolled into view when its index or its row's React key
   * (the count, for a row without a key) changes, so a filter that keeps the highlight at 0 still
   * shows its first result. */
  activeIndex?: number;
  /** Changes when the same index names a different result set or active item (for rows without keys). */
  activeScrollKey?: string;
  /** `measure` is set when `measureRows` is on: the row passes it as its `ref`, with `data-index={index}`. */
  renderRow(index: number, style: CSSProperties, measure?: (element: Element | null) => void): ReactNode;
  /** Rows size to their content: each is measured once rendered, and `estimateSize` is only the first guess. */
  measureRows?: boolean;
  /** The row's own identity (a task id). Measured heights are kept by it, so a row keeps its height when rows
   * before it leave or move. Without it they are kept by index, and the rows after a change are placed with
   * their old neighbors' heights until measured again (TanStack Virtual `getItemKey`). */
  itemKey?(index: number): string | number;
  className?: string;
  id?: string;
  /** The list's ARIA role and name (listbox, grid, ...); rows set theirs in renderRow. */
  role?: "listbox" | "grid" | "list";
  label?: string;
  /** With `role="grid"`: the whole list's row count (aria-rowcount), since only some rows are
   * mounted; rows then carry their own aria-rowindex. */
  rowCount?: number;
  overscan?: number;
  /** Use the closest matching ancestor as the viewport instead of creating a nested scroller. */
  scrollParent?: string;
  /** Fade overflowing rows on this list's own viewport. */
  fade?: boolean;
  /** A list that takes the keyboard itself (DrillList under a key style): -1, and its keys. */
  tabIndex?: number;
  onKeyDown?: KeyboardEventHandler<HTMLDivElement>;
}

/** Scrolls to the active row when its index or `key` changes: never on the user's own scrolling. The
 * active result can change without changing its numeric index (a filter keeps the highlight at 0). */
function useScrollToIndex(index: number | undefined, key: string, scrollTo: (index: number) => void) {
  const last = useRef<{ index: number; key: string } | null>(null);
  useLayoutEffect(() => {
    if (index === undefined || index < 0) {
      last.current = null;
      return;
    }
    if (last.current?.index === index && last.current.key === key) return;
    last.current = { index, key };
    scrollTo(index);
  });
}

export function VirtualList({
  count,
  estimateSize,
  activeIndex,
  activeScrollKey,
  renderRow,
  className,
  id,
  role = "listbox",
  label,
  overscan = 6,
  scrollParent,
  fade = false,
  measureRows = false,
  rowCount,
  tabIndex,
  onKeyDown,
  itemKey,
  rowCount,
}: VirtualListProps) {
  const scroller = useRef<HTMLDivElement | null>(null);
  const scrollEdges = useScrollEdges();
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      scroller.current = node;
      scrollEdges(fade && !scrollParent ? node : null);
    },
    [fade, scrollParent, scrollEdges],
  );
  const space = useRef<HTMLDivElement | null>(null);
  const [scrollMargin, setScrollMargin] = useState(0);
  const parent = useCallback(
    () => (scrollParent ? (scroller.current?.closest<HTMLElement>(scrollParent) ?? null) : scroller.current),
    [scrollParent],
  );
  // The list may follow a growing composer or cards. Observe each ancestor whose size can move
  // its origin, and measure after renders too. No animation loop; all observers disconnect.
  const measureMargin = useCallback(() => {
    const viewport = parent();
    if (!scrollParent || !viewport || !space.current) return;
    const next =
      space.current.getBoundingClientRect().top -
      viewport.getBoundingClientRect().top +
      viewport.scrollTop -
      viewport.clientTop;
    setScrollMargin((previous) => (previous === next ? previous : next));
  }, [parent, scrollParent]);
  useLayoutEffect(measureMargin);
  useLayoutEffect(() => {
    if (!scrollParent || typeof ResizeObserver === "undefined") return;
    const viewport = parent();
    const observer = new ResizeObserver(measureMargin);
    for (let node: HTMLElement | null = scroller.current; node; node = node.parentElement) {
      observer.observe(node);
      if (node === viewport) break;
    }
    return () => observer.disconnect();
  }, [measureMargin, parent, scrollParent]);
  const virtualizer = useVirtualizer({
    count,
    getScrollElement: parent,
    scrollMargin,
    estimateSize,
    ...(itemKey ? { getItemKey: itemKey } : {}),
    overscan,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (activeIndex !== undefined && activeIndex >= 0 && activeIndex < count && !indexes.includes(activeIndex)) {
        indexes.push(activeIndex);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  // The range extractor adds the active row to a measured range; before the first measure (no
  // viewport yet) there is no range, so the active row is added here from its estimated place.
  const items = virtualizer
    .getVirtualItems()
    .map((item) => ({ index: item.index, start: item.start, size: item.size }));
  if (
    activeIndex !== undefined &&
    activeIndex >= 0 &&
    activeIndex < count &&
    !items.some((item) => item.index === activeIndex)
  ) {
    const measured = virtualizer.measurementsCache[activeIndex];
    items.push({
      index: activeIndex,
      start: measured?.start ?? 0,
      size: measured?.size ?? estimateSize(activeIndex),
    });
  }
  const rows = items.map((item) =>
    renderRow(
      item.index,
      virtualRowStyle(item.start - scrollMargin, measureRows ? undefined : item.size),
      measureRows ? virtualizer.measureElement : undefined,
    ),
  );
  // The active row's identity: its React key (a filter's new first result at the same index), or the
  // count for a row without one. Not the count beside a key: a live list growing past the active
  // row (a feed) does not pull a list the user scrolled back to it.
  const activeRow = rows[items.findIndex((item) => item.index === activeIndex)];
  const activeRowKey = isValidElement(activeRow) && activeRow.key !== null ? `key:${activeRow.key}` : `count:${count}`;
  useScrollToIndex(activeIndex, `${activeRowKey}\0${activeScrollKey ?? ""}`, (index) =>
    virtualizer.scrollToIndex(index, { align: "auto" }),
  );
  return (
    // The layout the absolute rows need is inline, not only in ui.css: a page that does not load
    // ui.css (the agent pane) otherwise places the rows against the page and draws them over it.
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- `role` is the caller's (a listbox)
    <div
      ref={mounted}
      id={id}
      className={cx("ui-virtual", fade && !scrollParent && "ui-scroll-edge-fade", className)}
      style={{ overflow: scrollParent ? "visible" : "auto" }}
      role={role}
      aria-label={label}
      aria-rowcount={role === "grid" ? rowCount : undefined}
      tabIndex={tabIndex}
      onKeyDown={onKeyDown}
      aria-rowcount={role === "grid" ? rowCount : undefined}
    >
      <div
        ref={space}
        className="ui-virtual-space"
        style={{ position: "relative", width: "100%", height: virtualizer.getTotalSize() }}
      >
        {rows}
      </div>
    </div>
  );
}

const ROW_STYLES_KEPT = 4096;
const rowStyles = new Map<string, CSSProperties>();

/** A row's style is the same object for the same place and size, so a memoized row (one that takes
 * `style` as a prop) does not re-render when the list scrolls, a sibling is hovered or the caller
 * re-renders. A pure function of the geometry (no ref read at render, so the compiler keeps the
 * component); the oldest entries go past ROW_STYLES_KEPT. The objects are frozen: shared by lists. */
export function virtualRowStyle(offset: number, height: number | undefined): CSSProperties {
  const key = `${offset}|${height ?? ""}`;
  const kept = rowStyles.get(key);
  if (kept) return kept;
  const style: CSSProperties = Object.freeze({
    position: "absolute",
    top: 0,
    insetInlineStart: 0,
    width: "100%",
    transform: `translateY(${offset}px)`,
    ...(height === undefined ? {} : { height }),
  });
  if (rowStyles.size >= ROW_STYLES_KEPT) rowStyles.delete(rowStyles.keys().next().value!);
  rowStyles.set(key, style);
  return style;
}
