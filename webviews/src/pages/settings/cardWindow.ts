// A Settings card whose rows grow with the person's data (Shared Links, Keys) mounts only the rows
// near the page's viewport. The card's rows scroll with the page (`main.content`), not in a box of
// their own, so the window is placed by the list's offset in that scroller (`scrollMargin`). The rows
// stay the `.rows` element's children, so the card's outline and hairlines are unchanged; the room
// of the rows not mounted is a spacer before each mounted row that follows a gap.
// A row away from the window is still reached as when every row was mounted: the focused row's
// neighbours and the first and last rows stay mounted, so the browser's own Tab and Shift-Tab go on
// in list order and enter the list at its first or last row (no key handler); a row the card says to
// keep (a Revoke asking first) stays mounted, so its state survives a scroll.
// The window starts once the list has found its scroller, at the scroller's own offset: the page's
// scroller is shared by every card, so taking it over must not move it. A card's reveal waits for
// `ready` (the scroller found and the rows near it drawn), so it scrolls the page once, to the card
// as it settles.
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import {
  createContext,
  createElement,
  useCallback,
  useInsertionEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
} from "react";

const NO_KEYS: ReadonlySet<string> = new Set();

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

/** A mounted row: its place, its key and the room of the rows not mounted just before it. */
export type CardWindowItem = { index: number; key: string; gap: number };

export interface CardWindow {
  /** The `.rows` element's ref. */
  list: (node: HTMLElement | null) => void;
  /** The list has found its scroller (or that none scrolls) and its rows are drawn: a card's reveal
   * scrolls to it from here on, never before. */
  ready: boolean;
  /** The `.rows` element's bottom padding: the rows after the last one mounted (none while the
   * last row is kept mounted; kept for a list with no rows). */
  padBottom: number;
  /** The rows to mount, in order; a row with a `gap` follows a spacer of that height. */
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
  /** Rows that stay mounted wherever the page scrolls (a row with a confirmation open). */
  keep: ReadonlySet<string> = NO_KEYS,
): CardWindow {
  const [node, setNode] = useState<HTMLElement | null>(null);
  // undefined until the list mounts; null when nothing above it scrolls.
  const [scroller, setScroller] = useState<HTMLElement | null | undefined>(undefined);
  const list = useCallback((next: HTMLElement | null) => {
    setNode(next);
    setScroller(next ? scrollParent(next) : undefined);
  }, []);
  const [scrollMargin, setScrollMargin] = useState(0);
  // The first row's top in the scroller's content (the first row always stays mounted; a card may
  // draw a line of help above its rows): read once per render of the card and when the page's
  // column changes size (a card above it opening), one rect each, never per row.
  const measureMargin = useCallback(() => {
    if (!node || !scroller) return;
    const first = node.querySelector<HTMLElement>(':scope > [data-index="0"]') ?? node;
    const next = first.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
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
  // The browser's next tab stops from the focused row, and into the list from either side.
  const kept =
    focusedIndex >= 0 ? [focusedIndex, focusedIndex - 1, focusedIndex + 1, 0, keys.length - 1] : [0, keys.length - 1];
  for (const key of keep) kept.push(place.get(key) ?? -1);
  const getItemKey = useCallback((index: number) => keys[index]!, [keys]);
  const learned = useRef(new Map<string, number>());
  // `measure` (each row's ref, one function for the list's life) reads the kinds of the last commit,
  // written before React attaches the rows' refs; the measurements read this render's (TanStack reads
  // `estimateSize` only when the keys or the margin change, so a new function each render costs no pass).
  const kinds = useRef(kindOf);
  useInsertionEffect(() => {
    kinds.current = kindOf;
  });
  const estimateSize = (index: number) => learned.current.get(kindOf(index)) ?? estimate;
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so useCardWindow stays uncompiled on purpose; a card's rows stay the `.rows` element's own children in the page's shared scroller (placed by scrollMargin, with spacers, per-kind learned estimates and the focused and confirming rows kept), so ui/VirtualList does not fit.
  const virtualizer = useVirtualizer({
    count: keys.length,
    // Off until the list's scroller is known: TanStack reads its offset once and, when it takes the
    // scroller over, writes that offset back, so an offset read before (0) scrolled the whole page to
    // its top, undoing a deep link's reveal of the card. Read when it takes over, it moves nothing.
    enabled: scroller !== undefined,
    initialOffset: () => scroller?.scrollTop ?? 0,
    getScrollElement: () => scroller ?? null,
    estimateSize,
    getItemKey,
    overscan: OVERSCAN,
    scrollMargin,
    rangeExtractor: (range: Range) => {
      const indexes = new Set(defaultRangeExtractor(range));
      for (const index of kept) if (index >= 0 && index < keys.length) indexes.add(index);
      return [...indexes].sort((a, b) => a - b);
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
      ready: true,
      padBottom: 0,
      items: keys.map((key, index) => ({ index, key, gap: 0 })),
      measure,
      onFocus,
      onBlur,
    };
  }
  // Not started (the list's first commit): no row yet, and the rows' room at the estimate, as the
  // window's first pass draws it, so the page has its height when the reveal and the page's tail room
  // (useCurrentCard) read it.
  if (scroller === undefined) {
    return { list, ready: false, padBottom: keys.length * estimate, items: [], measure, onFocus, onBlur };
  }
  const virtual = virtualizer.getVirtualItems();
  const last = virtual.at(-1);
  const total = virtualizer.getTotalSize();
  let end = scrollMargin;
  const items = virtual.map((item) => {
    const gap = Math.max(0, item.start - end);
    end = item.end;
    return { index: item.index, key: String(item.key), gap };
  });
  return {
    list,
    // TanStack reads the scroller's size when it takes it over, so the commit that finds the
    // scroller has no row yet; the next one draws them.
    ready: keys.length === 0 || items.length > 0,
    padBottom: last ? Math.max(0, total - (last.end - scrollMargin)) : total,
    items,
    measure,
    onFocus,
    onBlur,
  };
}

/** The room of the rows not mounted before a mounted row: no role, nothing to read. */
export function windowGap(gap: number) {
  return gap > 0
    ? createElement("div", { className: "card-window-gap", "aria-hidden": true, style: { height: gap } })
    : null;
}

/** A change in flight in a windowed card (a revoke, a library change): every row's controls are
 * disabled until it answers. The controls read it, not the rows, so a change draws the controls
 * again and leaves each memo row's own lines be. */
export const CardBusy = createContext(false);
