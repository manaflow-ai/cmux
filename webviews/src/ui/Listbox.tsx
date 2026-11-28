// A focusable listbox of actions (recent items): one Tab stop, Up/Down/Home/End move, typing a
// letter jumps to the next row starting with it, Return or Space opens, a click opens. Base UI 1.8
// has no standalone listbox, so this is the wrapper's one implementation (aria-activedescendant).
//
// A list longer than LISTBOX_WINDOW_AFTER rows mounts only the rows near its viewport (one viewport
// of overscan each side) and the highlighted row, in list order between spacers, so it costs the
// same at a thousand rows as at ten thousand; windowed rows carry aria-posinset/aria-setsize. Rows
// may differ in height (a steer-queue row with its line and last message): each mounted row's height
// is kept by its key, and a row not yet measured is taken as the measured rows' mean. Each row is a
// memoized component: a highlight change re-renders the two rows it moved between. The list draws
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
  useMemo,
} from "react";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import type { ListCommand } from "./keyStyle";
import { useListKeys } from "./useListKeys";
import "./popupSurface.css";

export interface ListboxProps<T> {
  items: readonly T[];
  getKey(item: T): string;
  /** The text typeahead matches. */
  textValue(item: T): string;
  /** A row's content; `selected` is that row's own highlight, so a renderer that reads it, not the
   *  list's active index, stays the same function as the highlight moves and no other row draws again. */
  renderItem(item: T, index: number, selected: boolean): ReactNode;
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
  const scroller = useRef<HTMLDivElement | null>(null);
  const attachList = useCallback(
    (element: HTMLDivElement | null) => {
      scroller.current = element;
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

  const last = items.length - 1;
  // `app.keyStyle` (Vim j/k/gg/G/l, Emacs Ctrl-N/P/A/E/F): the same moves as the arrows, Home,
  // End and Return. The rest (h, /, Esc, paging) is not this list's, so it goes on unchanged.
  const listKeys = useListKeys({
    onCommand: (command) => {
      const to: Partial<Record<ListCommand, number>> = {
        "list.next": Math.min(last, current + 1),
        "list.previous": Math.max(0, current - 1),
        "list.first": 0,
        "list.last": last,
      };
      if (command in to) {
        if (items.length) setCurrentHighlight(to[command]!);
        return;
      }
      if (command !== "list.open") return false;
      const item = items[current];
      if (item) onOpen(item);
    },
  });

  // The list's own window: the scroller's offset and height, and each mounted row's measured height
  // by its key (a new Map when one changes, so the offsets below recompute).
  const ownWindow = visibleWindow === undefined && items.length > LISTBOX_WINDOW_AFTER;
  const [view, setView] = useState({ top: 0, height: 0 });
  const [heights, setHeights] = useState<ReadonlyMap<string, number>>(() => new Map());
  const readView = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    setView((previous) =>
      previous.top === node.scrollTop && previous.height === node.clientHeight
        ? previous
        : { top: node.scrollTop, height: node.clientHeight },
    );
  }, []);
  useLayoutEffect(() => {
    if (!ownWindow) return;
    readView();
    const node = scroller.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(readView);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ownWindow, readView]);
  // A mounted row that changes height on its own (an interface scale or text size change, a line
  // added to it) reads the heights again: one observer for the list, each row observed once.
  const [resized, setResized] = useState(0);
  const rowObserver = useRef<{ observer: ResizeObserver; rows: Set<Element> } | undefined>(undefined);
  useEffect(() => {
    if (!ownWindow || typeof ResizeObserver === "undefined") return;
    const watch = { observer: new ResizeObserver(() => setResized((count) => count + 1)), rows: new Set<Element>() };
    rowObserver.current = watch;
    return () => {
      watch.observer.disconnect();
      if (rowObserver.current === watch) rowObserver.current = undefined;
    };
  }, [ownWindow]);
  // When the mounted rows can change (the list, the scroll, the highlight, a row's size), read their
  // heights (only those, so it costs the window, not the list); a row whose height is new or changed
  // updates the map once. When every mounted row changed at once (two or more: an interface scale,
  // text size or look change), the heights measured before for the rows not mounted are dropped too,
  // so they take the mounted rows' mean and the list's length follows without visiting them.
  useLayoutEffect(() => {
    if (!ownWindow) return;
    const rows = scroller.current?.querySelectorAll<HTMLElement>(":scope > [role='option']") ?? [];
    const watch = rowObserver.current;
    if (watch) {
      for (const row of watch.rows)
        if (!row.isConnected) {
          watch.observer.unobserve(row);
          watch.rows.delete(row);
        }
      for (const row of rows)
        if (!watch.rows.has(row)) {
          watch.observer.observe(row);
          watch.rows.add(row);
        }
    }
    let next: Map<string, number> | undefined;
    let measured = 0;
    let changed = 0;
    const mounted = new Map<string, number>();
    for (const row of rows) {
      const index = Number(row.getAttribute("aria-posinset")) - 1;
      const item = items[index];
      const px = row.offsetHeight;
      if (item === undefined || px <= 0) continue;
      const key = getKey(item);
      mounted.set(key, px);
      const before = (next ?? heights).get(key);
      if (before !== undefined) measured += 1;
      if (before === px) continue;
      if (before !== undefined) changed += 1;
      next ??= new Map(heights);
      next.set(key, px);
    }
    if (changed >= 2 && changed === measured && heights.size > mounted.size) next = mounted;
    if (next) setHeights(next);
  }, [ownWindow, items, getKey, heights, view, current, resized]);
  const offsets = useMemo(
    () => (ownWindow ? listboxOffsets(items, getKey, heights) : undefined),
    [ownWindow, items, getKey, heights],
  );
  const segments = offsets
    ? listboxSegments(offsets, current, view.top, view.height)
    : visibleWindow
      ? [{ start: visibleWindow.start, end: visibleWindow.end, before: visibleWindow.topSpace }]
      : [{ start: 0, end: items.length, before: 0 }];
  const after = offsets
    ? Math.max(0, offsets[items.length] - offsets[segments.at(-1)?.end ?? 0])
    : (visibleWindow?.bottomSpace ?? 0);
  const windowed = ownWindow || visibleWindow !== undefined;
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
    listKeys(event);
    if (event.defaultPrevented) return;
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.altKey || event.ctrlKey) return;
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
      ref={attachList}
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
      onScroll={(event) => {
        if (ownWindow) readView();
        onScroll?.(event);
      }}
    >
      {/* One flat keyed array: a row that moves between segments keeps its element. Rows and spacers
          key apart ("row:", "spacer:"), so a caller's key that reads like a spacer's is still its row's. */}
      {segments.flatMap((segment, place) => [
        segment.before > 0 && <div key={`spacer:${place}`} aria-hidden="true" style={{ height: segment.before }} />,
        ...items.slice(segment.start, segment.end).map((item, offset) => {
          const index = segment.start + offset;
          return (
            <ListboxRow
              key={`row:${getKey(item)}`}
              item={item}
              index={index}
              id={getItemId?.(item, index) ?? `${id}-${index}`}
              className={rowClassName}
              selected={index === current}
              setSize={windowed ? items.length : undefined}
              renderItem={renderItem}
              itemAttributes={itemAttributes}
              content={renderItem(item, index, index === current)}
              attributes={itemAttributes?.(item, index)}
              onHover={hoverRow}
              onOpen={openRow}
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
    // A listbox shell is the live answer to what is typed in a field beside it (the composer's
    // slash, mention and emoji lists): its box follows the rows (ui/popupSettle.ts).
    <div ref={shellRef} className={cx(shellClassName, "ui-popup-scroll-shell")} data-popup-settle="results">
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
  }: ListboxRowProps) {
    return (
      <div
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
        <ListboxRowContent item={item} renderItem={renderItem} selected={selected} content={content} />
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

/** The row's content on its own: a highlight change re-renders the row, and its content only when
 * what it draws changed (renderItem takes `selected`, so the same item and callback count as the same
 * content only at the same highlight). */
const ListboxRowContent = memo(
  function ListboxRowContent({
    content,
  }: {
    item: unknown;
    renderItem: unknown;
    selected: boolean;
    content: ReactNode;
  }) {
    return content;
  },
  (previous, next) =>
    (Object.is(previous.item, next.item) &&
      Object.is(previous.renderItem, next.renderItem) &&
      previous.selected === next.selected) ||
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

/** Each row's top in a self-windowed list, and the list's height as the last entry: a row's measured
 * height by its key, else the measured rows' mean (ESTIMATED_ROW_PX before any is measured). */
export function listboxOffsets<T>(
  items: readonly T[],
  getKey: (item: T) => string,
  heights: ReadonlyMap<string, number>,
): Float64Array {
  let sum = 0;
  for (const px of heights.values()) sum += px;
  const estimate = heights.size > 0 ? sum / heights.size : ESTIMATED_ROW_PX;
  const offsets = new Float64Array(items.length + 1);
  for (let index = 0; index < items.length; index++)
    offsets[index + 1] = offsets[index] + (heights.get(getKey(items[index])) ?? estimate);
  return offsets;
}

/** The row whose box holds `px` (the last row past the end), by binary search over the offsets. */
function rowAt(offsets: Float64Array, px: number): number {
  const count = offsets.length - 1;
  let low = 0;
  let high = count;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (offsets[middle + 1] <= px) low = middle + 1;
    else high = middle;
  }
  return Math.min(low, Math.max(0, count - 1));
}

/** The row ranges a self-windowed list mounts, each with the spacer height before it: the rows in
 * view with one viewport of overscan each side, and the highlighted row when it is outside them (so
 * aria-activedescendant names a mounted row), in list order. `offsets` is listboxOffsets' (each row's
 * top, then the total). Before the viewport is measured (no layout yet) a viewport is taken as 400 px. */
export function listboxSegments(
  offsets: Float64Array,
  highlighted: number,
  scrollTop: number,
  viewportPx: number,
): { start: number; end: number; before: number }[] {
  const count = offsets.length - 1;
  if (count <= 0) return [{ start: 0, end: 0, before: 0 }];
  const height = viewportPx > 0 ? viewportPx : 400;
  const start = rowAt(offsets, Math.max(0, scrollTop - height));
  const end = Math.min(count, rowAt(offsets, scrollTop + 2 * height) + 1);
  if (highlighted < 0 || (highlighted >= start && highlighted < end)) return [{ start, end, before: offsets[start] }];
  if (highlighted < start)
    return [
      { start: highlighted, end: highlighted + 1, before: offsets[highlighted] },
      { start, end, before: offsets[start] - offsets[highlighted + 1] },
    ];
  return [
    { start, end, before: offsets[start] },
    { start: highlighted, end: highlighted + 1, before: offsets[highlighted] - offsets[end] },
  ];
}
