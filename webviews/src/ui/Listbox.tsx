// A focusable listbox of actions (recent items): one Tab stop, Up/Down/Home/End move, typing a
// letter jumps to the next row starting with it, Return or Space opens, a click opens. Base UI 1.8
// has no standalone listbox, so this is the wrapper's one implementation (aria-activedescendant).
//
// A list longer than LISTBOX_WINDOW_AFTER rows mounts only the rows near its viewport (one viewport
// of overscan each side) and the highlighted row, in list order between spacers, so it costs the
// same at a thousand rows as at ten thousand; windowed rows carry aria-posinset/aria-setsize. Each
// mounted row is measured (its fractional height, again whenever it resizes), so rows of different
// heights, a scaled interface and a row that grows after it mounts all place correctly. Each row is
// a memoized component: a highlight change re-renders the two rows it moved between. The list draws
// each mounted row's content and attributes itself and a row compares what they draw, not the
// callbacks' identity: a caller's inline renderItem re-renders no row, and one whose drawn output
// changed (data its closure reads) re-renders that row.
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type Ref,
  type UIEventHandler,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import "./popupSurface.css";

export interface ListboxProps<T> {
  items: readonly T[];
  getKey(item: T): string;
  /** The text typeahead matches. */
  textValue(item: T): string;
  renderItem(item: T, index: number): ReactNode;
  itemAttributes?(item: T, index: number): Record<string, string | undefined>;
  getItemId?(item: T, index: number): string;
  label: string;
  onOpen(item: T): void;
  /** Takes focus when it mounts, so arrows and Return work at once. */
  autoFocus?: boolean;
  className?: string;
  rowClassName?: string;
  /** The row highlighted when it mounts (the chosen one); default the first. */
  initialIndex?: number;
  /** Controlled highlight for fields that keep focus in an editor (slash/@ suggestions). */
  activeIndex?: number;
  onActiveIndexChange?(index: number): void;
  listRef?: Ref<HTMLDivElement>;
  /**
   * A popup list's glass (`ui-popup ui-glass ...`): drawn on an outer shell so the glass, rim and
   * exterior shadow stay outside the rows' edge fade (popupSurface.css `.ui-popup-scroll-shell`).
   */
  shellClassName?: string;
  shellRef?: Ref<HTMLDivElement>;
  empty?: ReactNode;
  /** Content rendered after the rows, such as a loading or status note. */
  footer?: ReactNode;
  "aria-busy"?: boolean;
  id?: string;
  /** The caller's own window (an editor-owned list that keeps its scroll); indices and ids remain
   * full-list values. Without it a list past LISTBOX_WINDOW_AFTER rows windows itself. */
  window?: { start: number; end: number; topSpace: number; bottomSpace: number };
  onScroll?: UIEventHandler<HTMLDivElement>;
}

const TYPEAHEAD_RESET_MS = 700;
/** Up to this many rows all mount (a menu's worth); past it the list windows itself. */
export const LISTBOX_WINDOW_AFTER = 50;
/** A row's height before any is measured. */
const ESTIMATED_ROW_PX = 28;
/** The viewport before the list has one (the first frame, or a DOM with no layout). */
const INITIAL_VIEW = { width: 320, height: 400 };

export function Listbox<T>({
  items,
  getKey,
  textValue,
  renderItem,
  itemAttributes,
  getItemId,
  label,
  onOpen,
  autoFocus = true,
  className,
  rowClassName,
  initialIndex = 0,
  activeIndex,
  onActiveIndexChange,
  listRef: externalListRef,
  shellClassName,
  shellRef,
  empty,
  footer,
  "aria-busy": ariaBusy,
  id: listId,
  window: visibleWindow,
  onScroll,
}: ListboxProps<T>) {
  const [highlight, setHighlight] = useState(Math.max(0, initialIndex));
  const currentHighlight = activeIndex ?? highlight;
  const setCurrentHighlight = (index: number) => {
    if (activeIndex === undefined) setHighlight(index);
    onActiveIndexChange?.(index);
  };
  const focused = useRef(false);
  const listEdges = useScrollEdges();
  const attachList = useCallback(
    (element: HTMLDivElement | null) => {
      listEdges(element);
      if (typeof externalListRef === "function") externalListRef(element);
      else if (externalListRef) externalListRef.current = element;
      if (!element || !autoFocus || focused.current) return;
      focused.current = true;
      element.focus({ preventScroll: true });
    },
    [autoFocus, externalListRef, listEdges],
  );
  const typed = useRef({ text: "", at: 0 });
  const id = useId();
  const current = items.length > 0 ? Math.min(currentHighlight, items.length - 1) : -1;
  const activeId = current >= 0 ? (getItemId?.(items[current], current) ?? `${id}-${current}`) : undefined;
  useEffect(() => {
    if (!activeId) return;
    const element = document.getElementById(activeId);
    element?.scrollIntoView?.({ block: "nearest" });
  }, [activeId]);

  // The list's own window, over measured rows: every mounted row reports its height (fractional,
  // from one ResizeObserver over the mounted rows only), and a row not yet measured is taken as the
  // first one measured. The rows stay in the list's flow, with spacers for the rows not mounted.
  const ownWindow = visibleWindow === undefined && items.length > LISTBOX_WINDOW_AFTER;
  const scroller = useRef<HTMLDivElement | null>(null);
  const [firstRowPx, setFirstRowPx] = useState(0);
  const [rowGap, setRowGap] = useState(0);
  const estimate = firstRowPx || ESTIMATED_ROW_PX;
  const virtualizer = useVirtualizer<HTMLDivElement, Element>({
    count: ownWindow ? items.length : 0,
    getScrollElement: () => scroller.current,
    estimateSize: () => estimate,
    getItemKey: (index) => (items[index] === undefined ? index : getKey(items[index])),
    gap: rowGap,
    initialRect: INITIAL_VIEW,
    // One viewport of rows each side.
    overscan: Math.ceil((scroller.current?.clientHeight || INITIAL_VIEW.height) / estimate),
    // The highlighted row stays mounted wherever the list is scrolled, so aria-activedescendant
    // always names a row.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (current >= 0 && current < items.length && !indexes.includes(current)) {
        indexes.push(current);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
    // A row's height as laid out, fractional: the library's own measure rounds it (a 30.8 px row at
    // an interface scale of 1.1 counts as 31, and the list grows a pixel every five rows). With no
    // resize entry (a row mounting), a size measured before stands, as the library does. A DOM with
    // no layout measures 0: keep the estimate there.
    measureElement: (element, entry, instance) => {
      const box = entry?.borderBoxSize?.[0];
      if (box) return box.blockSize || estimate;
      if (!entry) {
        const cached = instance.itemSizeCache.get(instance.options.getItemKey(instance.indexFromElement(element)));
        if (cached !== undefined) return cached;
      }
      return element.getBoundingClientRect().height || estimate;
    },
  });
  useLayoutEffect(() => {
    if (!ownWindow || firstRowPx > 0) return;
    const row = scroller.current?.querySelector<HTMLElement>(":scope > [role='option']");
    const height = row?.getBoundingClientRect().height ?? 0;
    if (height > 0) setFirstRowPx(height);
    const node = scroller.current;
    if (!node) return;
    // A flex or grid list puts its gap between rows and spacers alike.
    const gap = Number.parseFloat(getComputedStyle(node).rowGap);
    if (Number.isFinite(gap) && gap > 0) setRowGap(gap);
    // Again when the rows change, until one has a height (a list laid out after it mounted).
  }, [ownWindow, firstRowPx, items]);
  const segments = ownWindow
    ? listboxSegments(virtualizer.getVirtualItems(), virtualizer.getTotalSize(), rowGap)
    : visibleWindow
      ? [{ start: visibleWindow.start, end: visibleWindow.end, before: visibleWindow.topSpace }]
      : [{ start: 0, end: items.length, before: 0 }];
  const after = ownWindow
    ? ((segments.at(-1) as { after?: number } | undefined)?.after ?? 0)
    : (visibleWindow?.bottomSpace ?? 0);
  const measureRow = ownWindow ? virtualizer.measureElement : undefined;
  const windowed = ownWindow || visibleWindow !== undefined;
  const attachScroller = useCallback(
    (element: HTMLDivElement | null) => {
      scroller.current = element;
      attachList(element);
    },
    [attachList],
  );
  // The rows' handlers are stable (a memoized row must not re-render for a new closure); they read
  // the list's latest state when they run.
  const latest = useRef({ current, items, onOpen, setCurrentHighlight });
  useLayoutEffect(() => {
    latest.current = { current, items, onOpen, setCurrentHighlight };
  });
  const hoverRow = useCallback((index: number) => {
    if (index !== latest.current.current) latest.current.setCurrentHighlight(index);
  }, []);
  const openRow = useCallback((index: number) => {
    const item = latest.current.items[index];
    if (item !== undefined) latest.current.onOpen(item);
  }, []);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.altKey || event.ctrlKey) return;
    const last = items.length - 1;
    const moves: Record<string, number> = {
      ArrowDown: Math.min(last, current + 1),
      ArrowUp: Math.max(0, current - 1),
      Home: 0,
      End: last,
    };
    if (event.key in moves) {
      event.preventDefault();
      setCurrentHighlight(moves[event.key]);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const item = items[current];
      if (item) onOpen(item);
    } else if (event.key.length === 1 && /\S/.test(event.key)) {
      const now = event.timeStamp;
      const joined = now - typed.current.at > TYPEAHEAD_RESET_MS ? event.key : typed.current.text + event.key;
      typed.current = { text: joined, at: now };
      // The same letter again cycles through the rows starting with it.
      const text = /^(.)\1*$/su.test(joined) ? event.key : joined;
      const wanted = text.toLocaleLowerCase();
      const order = items.map((_, index) => (current + (text.length === 1 ? 1 : 0) + index) % items.length);
      const match = order.find((index) => textValue(items[index]).toLocaleLowerCase().startsWith(wanted));
      if (match !== undefined) {
        event.preventDefault();
        setCurrentHighlight(match);
      }
    }
  };

  const list = (
    <div
      ref={attachScroller}
      id={listId}
      className={cx("ui-listbox ui-scroll-edge-fade", shellClassName !== undefined && "ui-popup-scroll", className)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native select cannot hold rich rows.
      role="listbox"
      // Controlled highlights belong to a field that keeps virtual focus (for example the
      // composer editor). Keep that list out of the Tab order; the field owns keyboard focus.
      tabIndex={activeIndex === undefined ? 0 : undefined}
      aria-label={label}
      aria-busy={ariaBusy || undefined}
      aria-activedescendant={activeId}
      onKeyDown={onKeyDown}
      onScroll={onScroll}
    >
      {/* One flat keyed array: a row that moves between segments keeps its element. Rows' keys and
          spacers' keys have their own prefixes, so no key a caller's getKey gives can match a spacer. */}
      {segments.flatMap((segment, place) => [
        segment.before > 0 && <div key={`space:${place}`} aria-hidden="true" style={{ height: segment.before }} />,
        ...items.slice(segment.start, segment.end).map((item, offset) => {
          const index = segment.start + offset;
          return (
            <ListboxRow
              key={`row:${getKey(item)}`}
              index={index}
              id={getItemId?.(item, index) ?? `${id}-${index}`}
              className={rowClassName}
              selected={index === current}
              setSize={windowed ? items.length : undefined}
              item={item}
              renderItem={renderItem}
              itemAttributes={itemAttributes}
              content={renderItem(item, index)}
              attributes={itemAttributes?.(item, index)}
              onHover={hoverRow}
              onOpen={openRow}
              measure={measureRow}
            />
          );
        }),
      ])}
      {after > 0 && <div aria-hidden="true" style={{ height: after }} />}
      {items.length === 0 && empty}
      {footer}
    </div>
  );
  if (shellClassName === undefined) return list;
  return (
    <div ref={shellRef} className={cx(shellClassName, "ui-popup-scroll-shell")}>
      {list}
    </div>
  );
}

interface ListboxRowProps {
  index: number;
  id: string;
  className?: string;
  selected: boolean;
  /** Set when the list is windowed: the full length, for aria-setsize and aria-posinset. */
  setSize?: number;
  /** The row's item and the callbacks that drew it: unchanged, the row is (a stable callback's
   * output may hold a new handler or style object each call, which no comparison would match). */
  item: unknown;
  renderItem: unknown;
  itemAttributes: unknown;
  /** What the row draws, and its attributes: else compared by value, so a new callback identity
   * alone (a caller's inline arrow) re-renders nothing. */
  content: ReactNode;
  attributes?: Record<string, string | undefined>;
  onHover(index: number): void;
  onOpen(index: number): void;
  /** Set when the list windows itself: reports the row's height (it carries data-index). */
  measure?: (element: Element | null) => void;
}

/** The row props compared together, by the item and its callbacks or else by what they draw. */
const DRAWN_BY: ReadonlySet<keyof ListboxRowProps> = new Set([
  "item",
  "renderItem",
  "itemAttributes",
  "content",
  "attributes",
]);

const ListboxRow = memo(
  function ListboxRow({
    index,
    id,
    className,
    selected,
    setSize,
    item,
    renderItem,
    content,
    attributes,
    onHover,
    onOpen,
    measure,
  }: ListboxRowProps) {
    return (
      <div
        ref={measure}
        data-index={measure ? index : undefined}
        id={id}
        className={cx("ui-listbox-row", className)}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rows of the listbox above.
        role="option"
        tabIndex={-1}
        aria-selected={selected}
        aria-posinset={setSize === undefined ? undefined : index + 1}
        aria-setsize={setSize}
        {...attributes}
        onMouseMove={() => onHover(index)}
        onMouseDown={(event) => {
          // Secondary/middle press and macOS Control-click keep the system context menu.
          if (event.button !== 0 || event.ctrlKey) return;
          event.preventDefault();
          onOpen(index);
        }}
      >
        <ListboxRowContent item={item} renderItem={renderItem} content={content} />
      </div>
    );
  },
  (previous, next) => {
    for (const key of Object.keys(next) as (keyof ListboxRowProps)[]) {
      if (DRAWN_BY.has(key)) continue;
      if (!Object.is(previous[key], next[key])) return false;
    }
    const sameItem = Object.is(previous.item, next.item);
    return (
      ((sameItem && Object.is(previous.itemAttributes, next.itemAttributes)) ||
        sameAttributes(previous.attributes, next.attributes)) &&
      ((sameItem && Object.is(previous.renderItem, next.renderItem)) || sameDrawn(previous.content, next.content))
    );
  },
);

/** The row's content on its own: a highlight change re-renders the row, not what it draws. */
const ListboxRowContent = memo(
  function ListboxRowContent({ content }: { item: unknown; renderItem: unknown; content: ReactNode }) {
    return content;
  },
  (previous, next) =>
    (Object.is(previous.item, next.item) && Object.is(previous.renderItem, next.renderItem)) ||
    sameDrawn(previous.content, next.content),
);

function sameAttributes(
  a: Record<string, string | undefined> | undefined,
  b: Record<string, string | undefined> | undefined,
): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && a[key] === b[key]);
}

/** Past this depth of nested elements, drawn output counts as changed. */
const SAME_DRAWN_DEPTH = 12;

/** Whether two drawn outputs (React nodes) draw the same: equal primitives, or elements of the same
 * kind, type and key whose props are each `Object.is`-equal or, for elements and arrays, the same
 * drawn output again. A function compares by identity, so an inline handler counts as a change. */
export function sameDrawn(a: unknown, b: unknown, depth = 0): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (depth >= SAME_DRAWN_DEPTH) return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((value, index) => sameDrawn(value, b[index], depth + 1));
  }
  const x = a as { $$typeof?: unknown; type?: unknown; key?: unknown; props?: Record<string, unknown> };
  const y = b as typeof x;
  if (typeof x.$$typeof !== "symbol" || x.$$typeof !== y.$$typeof) return false;
  if (x.type !== y.type || x.key !== y.key || !x.props || !y.props) return false;
  const keys = Object.keys(x.props);
  if (keys.length !== Object.keys(y.props).length) return false;
  return keys.every((key) => Object.hasOwn(y.props!, key) && sameDrawn(x.props![key], y.props![key], depth + 1));
}

/** The rows a self-windowed list mounts, as ranges of consecutive rows, each with the spacer height
 * before it, and the spacer after the last: from the virtualizer's mounted rows (their measured
 * offsets and sizes) and the whole list's height. With a flex or grid `gap`, the list also puts one
 * gap after each spacer, so a spacer is that much shorter. */
export function listboxSegments(
  rows: readonly { index: number; start: number; end: number }[],
  total: number,
  gap = 0,
): { start: number; end: number; before: number; after?: number }[] {
  const segments: { start: number; end: number; before: number; after?: number }[] = [];
  let end = -gap;
  for (const row of rows) {
    const last = segments.at(-1);
    if (last && last.end === row.index) last.end += 1;
    else
      segments.push({
        start: row.index,
        end: row.index + 1,
        before: Math.max(0, row.start - end - (last ? 2 : 1) * gap),
      });
    end = row.end;
  }
  const last = segments.at(-1);
  if (last) last.after = Math.max(0, total - end - gap);
  return segments;
}
