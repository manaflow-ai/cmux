// A virtualized list over TanStack Virtual. Only the rows near the viewport are in the DOM, plus
// the active row (`activeIndex`), so `aria-activedescendant` never names a missing element, and the
// list scrolls to the active row when it changes. Each row gets `aria-posinset`/`aria-setsize` from
// the caller's renderRow (it receives the index and the absolute count).
import { useLayoutEffect, useRef, type CSSProperties, type ReactNode } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { cx } from "./cx";

export interface VirtualListProps {
  count: number;
  /** Row height in pixels (rows may differ; this is the estimate before measuring). */
  estimateSize(index: number): number;
  /** The highlighted row: always rendered, scrolled into view when it changes. */
  activeIndex?: number;
  renderRow(index: number, style: CSSProperties): ReactNode;
  className?: string;
  id?: string;
  /** The list's ARIA role and name (listbox, grid, ...); rows set theirs in renderRow. */
  role?: "listbox" | "grid" | "list";
  label?: string;
  overscan?: number;
}

/** Scrolls `scrollTo(index)` whenever `index` changes (a narrow wrapper around the one effect). */
function useScrollToIndex(index: number | undefined, scrollTo: (index: number) => void) {
  const last = useRef<number | undefined>(undefined);
  useLayoutEffect(() => {
    if (index === undefined || index < 0 || index === last.current) return;
    last.current = index;
    scrollTo(index);
  });
}

export function VirtualList({
  count,
  estimateSize,
  activeIndex,
  renderRow,
  className,
  id,
  role = "listbox",
  label,
  overscan = 6,
}: VirtualListProps) {
  const scroller = useRef<HTMLDivElement | null>(null);
  const virtualizer = useVirtualizer({
    count,
    getScrollElement: () => scroller.current,
    estimateSize,
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
  useScrollToIndex(activeIndex, (index) => virtualizer.scrollToIndex(index, { align: "auto" }));
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
    items.push({ index: activeIndex, start: measured?.start ?? 0, size: measured?.size ?? estimateSize(activeIndex) });
  }
  return (
    <div ref={scroller} id={id} className={cx("ui-virtual", className)} role={role} aria-label={label}>
      <div className="ui-virtual-space" style={{ height: virtualizer.getTotalSize() }}>
        {items.map((item) =>
          renderRow(item.index, {
            position: "absolute",
            top: 0,
            insetInlineStart: 0,
            width: "100%",
            transform: `translateY(${item.start}px)`,
            height: item.size,
          }),
        )}
      </div>
    </div>
  );
}
