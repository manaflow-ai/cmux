// A focusable listbox of actions (recent items): one Tab stop, Up/Down/Home/End move, typing a
// letter jumps to the next row starting with it, Return or Space opens, a click opens. Base UI 1.8
// has no standalone listbox, so this is the wrapper's one implementation (aria-activedescendant).
//
// A list longer than LISTBOX_WINDOW_AFTER rows mounts only the rows near its viewport (one viewport
// of overscan each side) and the highlighted row, in list order between spacers, so it costs the
// same at a thousand rows as at ten thousand; windowed rows carry aria-posinset/aria-setsize. Each
// row is a memoized component: a highlight change re-renders the two rows it moved between.
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
/** A row's height before one is measured. */
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

  // The list's own window: the scroller's offset and height, and a row's measured height.
  const ownWindow = visibleWindow === undefined && items.length > LISTBOX_WINDOW_AFTER;
  const [view, setView] = useState({ top: 0, height: 0 });
  const [rowPx, setRowPx] = useState(0);
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
  useLayoutEffect(() => {
    if (!ownWindow || rowPx > 0) return;
    const row = scroller.current?.querySelector<HTMLElement>(":scope > [role='option']");
    if (row && row.offsetHeight > 0) setRowPx(row.offsetHeight);
    // Again when the rows change, until one has a height (a list laid out after it mounted).
  }, [ownWindow, rowPx, items]);
  const segments = ownWindow
    ? listboxSegments(items.length, current, view.top, view.height, rowPx || ESTIMATED_ROW_PX)
    : visibleWindow
      ? [{ start: visibleWindow.start, end: visibleWindow.end, before: visibleWindow.topSpace }]
      : [{ start: 0, end: items.length, before: 0 }];
  const after = ownWindow
    ? Math.max(0, items.length - (segments.at(-1)?.end ?? 0)) * (rowPx || ESTIMATED_ROW_PX)
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
      {/* One flat keyed array: a row that moves between segments keeps its element. */}
      {segments.flatMap((segment, place) => [
        segment.before > 0 && <div key={`space-${place}`} aria-hidden="true" style={{ height: segment.before }} />,
        ...items.slice(segment.start, segment.end).map((item, offset) => {
          const index = segment.start + offset;
          return (
            <ListboxRow
              key={getKey(item)}
              item={item}
              index={index}
              id={getItemId?.(item, index) ?? `${id}-${index}`}
              className={rowClassName}
              selected={index === current}
              setSize={windowed ? items.length : undefined}
              renderItem={renderItem}
              itemAttributes={itemAttributes}
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
    <div ref={shellRef} className={cx(shellClassName, "ui-popup-scroll-shell")}>
      {list}
    </div>
  );
}

interface ListboxRowProps<T> {
  item: T;
  index: number;
  id: string;
  className?: string;
  selected: boolean;
  /** Set when the list is windowed: the full length, for aria-setsize and aria-posinset. */
  setSize?: number;
  renderItem(item: T, index: number): ReactNode;
  itemAttributes?(item: T, index: number): Record<string, string | undefined>;
  onHover(index: number): void;
  onOpen(index: number): void;
}

const ListboxRow = memo(function ListboxRow<T>({
  item,
  index,
  id,
  className,
  selected,
  setSize,
  renderItem,
  itemAttributes,
  onHover,
  onOpen,
}: ListboxRowProps<T>) {
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
      {...itemAttributes?.(item, index)}
      onMouseMove={() => onHover(index)}
      onMouseDown={(event) => {
        // Secondary/middle press and macOS Control-click keep the system context menu.
        if (event.button !== 0 || event.ctrlKey) return;
        event.preventDefault();
        onOpen(index);
      }}
    >
      {renderItem(item, index)}
    </div>
  );
}) as <T>(props: ListboxRowProps<T> & { key?: string }) => ReactNode;

/** The row ranges a self-windowed list mounts, each with the spacer height before it: the rows in
 * view with one viewport of overscan each side, and the highlighted row when it is outside them (so
 * aria-activedescendant names a mounted row), in list order. Before the viewport is measured (no
 * layout yet) a viewport is taken as 400 px. */
export function listboxSegments(
  count: number,
  highlighted: number,
  scrollTop: number,
  viewportPx: number,
  rowPx: number,
): { start: number; end: number; before: number }[] {
  const height = viewportPx > 0 ? viewportPx : 400;
  const overscan = Math.ceil(height / rowPx);
  const start = Math.max(0, Math.floor(scrollTop / rowPx) - overscan);
  const end = Math.min(count, Math.ceil((scrollTop + height) / rowPx) + overscan);
  if (highlighted < 0 || (highlighted >= start && highlighted < end)) return [{ start, end, before: start * rowPx }];
  if (highlighted < start)
    return [
      { start: highlighted, end: highlighted + 1, before: highlighted * rowPx },
      { start, end, before: (start - highlighted - 1) * rowPx },
    ];
  return [
    { start, end, before: start * rowPx },
    { start: highlighted, end: highlighted + 1, before: (highlighted - end) * rowPx },
  ];
}
