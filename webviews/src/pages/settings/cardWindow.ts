// A Settings card whose rows grow with the person's data (Shared Links, Keys) mounts only the rows
// near the page's viewport. The card's rows scroll with the page (`main.content`), not in a box of
// their own, so the window is placed by the list's offset in that scroller (`scrollMargin`), and the
// rows above and below the window are the list's own padding: the rows stay the `.rows` element's
// children, so the card's outline and hairlines are unchanged.
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useCallback, useLayoutEffect, useMemo, useRef, useState, type FocusEvent } from "react";

/** About one viewport of rows each side (a row is 60 to 90 px; the page is 600 to 1,000 tall). */
const OVERSCAN = 12;

/** The page's scroller: Settings' `main.content`, else the nearest ancestor that scrolls. */
function scrollParent(node: HTMLElement): HTMLElement | null {
  const content = node.closest<HTMLElement>("main.content");
  if (content) return content;
  for (let parent = node.parentElement; parent; parent = parent.parentElement) {
    const overflow = getComputedStyle(parent).overflowY;
    if (overflow === "auto" || overflow === "scroll") return parent;
  }
  return null;
}

export type CardWindowItem = { index: number; key: string };

export interface CardWindow {
  /** The `.rows` element's ref. */
  list: (node: HTMLElement | null) => void;
  /** The `.rows` element's top and bottom padding: the rows outside the window. */
  padTop: number;
  padBottom: number;
  /** The rows to mount, in order. */
  items: CardWindowItem[];
  /** Each mounted row's ref; the row carries `data-index`. */
  measure: (node: HTMLElement | null) => void;
  /** On the `.rows` element: the row holding focus stays mounted while it scrolls away. */
  onFocus: (event: FocusEvent<HTMLElement>) => void;
  onBlur: (event: FocusEvent<HTMLElement>) => void;
}

/**
 * The window over `keys` (one per row, in order). `estimate` sizes a row not yet measured until the
 * first row of its kind (`kindOf`: rows of one kind draw the same lines) is measured; that size
 * then stands for every unmeasured row of the kind, so the page's height is close before a scroll
 * and the rows a scroll mounts do not move the rest.
 */
export function useCardWindow(
  keys: readonly string[],
  estimate: number,
  kindOf: (index: number) => string = () => "",
): CardWindow {
  const [node, setNode] = useState<HTMLElement | null>(null);
  // undefined until the list mounts; null when nothing above it scrolls.
  const [scroller, setScroller] = useState<HTMLElement | null | undefined>(undefined);
  const list = useCallback((next: HTMLElement | null) => {
    setNode(next);
    setScroller(next ? scrollParent(next) : undefined);
  }, []);
  const [scrollMargin, setScrollMargin] = useState(0);
  // The list's top in the scroller's content: read once per render of the card and when the page's
  // column changes size (a card above it opening), one rect each, never per row.
  const measureMargin = useCallback(() => {
    if (!node || !scroller) return;
    const next = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
    setScrollMargin((previous) => (Math.abs(previous - next) < 0.5 ? previous : next));
  }, [node, scroller]);
  useLayoutEffect(measureMargin);
  useLayoutEffect(() => {
    const column = scroller?.querySelector(":scope > .column") ?? scroller?.firstElementChild;
    if (!column || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureMargin);
    observer.observe(column);
    return () => observer.disconnect();
  }, [measureMargin, scroller]);

  // Built once per list: a key's row, so the focused row is found without a scan.
  const place = useMemo(() => new Map(keys.map((key, index) => [key, index])), [keys]);
  const [focused, setFocused] = useState<string | null>(null);
  const focusedIndex = focused === null ? -1 : (place.get(focused) ?? -1);
  const getItemKey = useCallback((index: number) => keys[index]!, [keys]);
  const learned = useRef(new Map<string, number>());
  const kinds = useRef(kindOf);
  kinds.current = kindOf;
  const estimateSize = useCallback(
    (index: number) => learned.current.get(kinds.current(index)) ?? estimate,
    [estimate],
  );
  const virtualizer = useVirtualizer({
    count: keys.length,
    getScrollElement: () => scroller ?? null,
    estimateSize,
    getItemKey,
    overscan: OVERSCAN,
    scrollMargin,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (focusedIndex >= 0 && !indexes.includes(focusedIndex)) {
        indexes.push(focusedIndex);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  const measure = useCallback(
    (row: HTMLElement | null) => {
      const kind = row ? kinds.current(Number(row.dataset.index)) : "";
      if (row && !learned.current.has(kind) && row.offsetHeight > 0) learned.current.set(kind, row.offsetHeight);
      virtualizer.measureElement(row);
    },
    [virtualizer],
  );
  const rowOf = (event: FocusEvent<HTMLElement>, target: EventTarget | null) => {
    const row = target instanceof Element ? target.closest<HTMLElement>("[data-index]") : null;
    if (!row || !event.currentTarget.contains(row)) return null;
    return keys[Number(row.dataset.index)] ?? null;
  };
  const onFocus = (event: FocusEvent<HTMLElement>) => setFocused(rowOf(event, event.target));
  const onBlur = (event: FocusEvent<HTMLElement>) => {
    if (rowOf(event, event.relatedTarget) === null) setFocused(null);
  };

  // No scroller (a gallery that draws the card alone): every row, as before.
  if (scroller === null) {
    return {
      list,
      padTop: 0,
      padBottom: 0,
      items: keys.map((key, index) => ({ index, key })),
      measure,
      onFocus,
      onBlur,
    };
  }
  const virtual = virtualizer.getVirtualItems();
  const first = virtual[0];
  const last = virtual.at(-1);
  const total = virtualizer.getTotalSize();
  return {
    list,
    padTop: first ? first.start - scrollMargin : 0,
    padBottom: last ? Math.max(0, total - (last.end - scrollMargin)) : total,
    items: virtual.map((item) => ({ index: item.index, key: String(item.key) })),
    measure,
    onFocus,
    onBlur,
  };
}
