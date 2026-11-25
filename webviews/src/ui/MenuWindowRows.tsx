// One section's rows in a windowed composer menu (menuWindow.ts holds the window state and keys).
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range, type Virtualizer } from "@tanstack/react-virtual";
import { ROW_ATTRIBUTE, type MenuWindow, SCROLLER, MIN_ROW_HEIGHT, focusRow, sectionStarts } from "./menuWindow";

const ROW_STYLE = Object.freeze({ display: "flow-root" });

/**
 * One section's rows in a windowed menu: those within a viewport of the menu's viewport each side,
 * and the focused row. `row(index)` draws row `index` (a memoized row, so a row that stays mounted
 * does not draw again as the menu scrolls).
 */
export function MenuWindowRows({
  menu,
  section,
  start,
  count,
  estimate,
  opensAt,
  row,
}: {
  menu: MenuWindow;
  section: number;
  /** The section's first row in the menu's order (sectionStarts). */
  start: number;
  count: number;
  /** A row's height before it is measured. */
  estimate: number;
  /** This section's row the menu opens scrolled to. */
  opensAt?: number;
  row(index: number): ReactNode;
}) {
  const top = useRef<HTMLDivElement | null>(null);
  const [margin, setMargin] = useState(0);
  const [viewport, setViewport] = useState(0);
  const scroller = useCallback(() => top.current?.closest<HTMLElement>(SCROLLER) ?? null, []);
  // The virtualizer, for the range to read its place (set after the first draw, which has no viewport).
  const [self] = useState<{ current?: Virtualizer<HTMLElement, Element> }>(() => ({}));
  // The rows within one viewport of the visible ones, by their measured place: a section wholly out of
  // that band draws none (TanStack's count overscan would draw its first rows). The focused row stays
  // drawn, so focus is never on a removed element.
  const rangeExtractor = useCallback(
    (range: Range) => {
      let indexes = defaultRangeExtractor(range);
      const virtualizer = self.current;
      const height = virtualizer?.scrollRect?.height ?? 0;
      if (virtualizer && height > 0) {
        const offset = virtualizer.scrollOffset ?? 0;
        const measurements = virtualizer.measurementsCache;
        indexes = indexes.filter((index) => {
          const item = measurements[index];
          return item !== undefined && item.end > offset - height && item.start < offset + 2 * height;
        });
      }
      const focused = menu.focused - start;
      if (focused >= 0 && focused < count && !indexes.includes(focused)) {
        indexes.push(focused);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
    [menu, start, count, self],
  );
  const virtualizer = useVirtualizer({
    count,
    getScrollElement: scroller,
    estimateSize: () => estimate,
    // Enough rows for a viewport each side at the smallest row; the range keeps those within one.
    overscan: Math.max(1, Math.ceil(viewport / MIN_ROW_HEIGHT)),
    scrollMargin: margin,
    rangeExtractor,
  });
  // Where the rows start in the scroller, and the scroller's height: measured when they mount and when
  // the scroller or a section in it changes size (one observer per list, never one per row).
  useLayoutEffect(() => {
    const element = scroller();
    if (!element) return;
    const measure = () => {
      if (!top.current) return;
      const next = top.current.getBoundingClientRect().top - element.getBoundingClientRect().top + element.scrollTop;
      setMargin((old) => (Math.abs(old - next) < 0.5 ? old : next));
      setViewport((old) => (old === element.clientHeight ? old : element.clientHeight));
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    for (const child of element.children) observer.observe(child);
    return () => observer.disconnect();
  }, [scroller, start]);
  useLayoutEffect(() => {
    self.current = virtualizer;
  }, [self, virtualizer]);
  useEffect(
    () => menu.register(section, (index) => virtualizer.scrollToIndex(index, { align: "auto" })),
    [menu, section, virtualizer],
  );
  // Open at the current row.
  const opened = useRef(false);
  useLayoutEffect(() => {
    if (opened.current || viewport === 0) return;
    opened.current = true;
    if (opensAt !== undefined && opensAt >= 0) virtualizer.scrollToIndex(opensAt, { align: "center" });
  }, [opensAt, viewport, virtualizer]);
  // A row the keyboard moved to before it was drawn takes focus once it is, the frame after Base UI has
  // counted it among its items (its index is the highlight); and the focused row keeps the highlight
  // when rows above it come and go.
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      const scope = top.current?.closest<HTMLElement>(".ui-popup");
      if (!scope) return;
      const pending = menu.pending;
      if (pending !== undefined && pending >= start && pending < start + count) {
        const element = scope.querySelector<HTMLElement>(`[${ROW_ATTRIBUTE}="${pending}"]`);
        if (element) {
          menu.pending = undefined;
          focusRow(element);
          return;
        }
      }
      menu.settleOpen(scope);
      menu.resync(scope);
    });
    return () => cancelAnimationFrame(frame);
  });
  const items = virtualizer.getVirtualItems();
  const rows: ReactNode[] = [];
  let cursor = margin;
  for (const item of items) {
    if (rows.length > 0 && item.start > cursor)
      rows.push(<div key={`gap-${item.index}`} aria-hidden="true" style={{ height: item.start - cursor }} />);
    rows.push(
      <div
        key={item.index}
        data-index={item.index}
        {...{ [ROW_ATTRIBUTE]: start + item.index }}
        ref={virtualizer.measureElement}
        style={ROW_STYLE}
        onFocus={() => menu.rowFocused(start + item.index)}
      >
        {row(item.index)}
      </div>,
    );
    cursor = item.end;
  }
  const first = items[0]?.start ?? margin;
  const end = virtualizer.getTotalSize() + margin;
  return (
    <>
      <div ref={top} aria-hidden="true" style={{ height: Math.max(0, first - margin) }} />
      {rows}
      <div aria-hidden="true" style={{ height: Math.max(0, end - cursor) }} />
    </>
  );
}
