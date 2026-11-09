// The Messages page's conversation list, ported from the native Home list (`HomeSidebarView` over
// MessagesLab's `CmuxSidebarView`): the header (search, the Unread toggle, the Unread chip while it
// is on), the pinned grid, then every other conversation as a row, and under the list the quiet
// Cloud note and Message Requests. It owns no data: the page hands it the model (list/model.ts)
// after every change and handles the choices.
//
// - A click selects and opens (the message box takes the keyboard); Command-, Shift- and
//   Control-clicks only select. Up and Down move the selection through the tiles, then the rows;
//   Return opens it; Command-F searches. A letter typed in the list goes to the message box, as the
//   native Home routed it (pageCommands.ts `followTyping`), not to a search.
// - After the conversations, the team members with no DM yet; a search lists the matching people
//   under "Teammates". Choosing one starts the DM.
// - A two-finger swipe on a row shows its actions (swipe.ts): Mark as Read or Unread, Delete.
// - A drag moves a pinned tile to another place, drops a row into the grid (pinning it there), or
//   takes a tile out of the grid (unpinning it). Tiles move to their new places together.
// - A right-click (or Shift-F10 on the list) opens the row's menu: Pin or Unpin, Mark as Read or
//   Unread, the host's catalog items (Chat Colors…, Group Info and the rest), Delete Conversation….
// - Only the rows in view (and a screen's overscan) are in the DOM: cost stays the same at 10,000
//   conversations.
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent as ReactWheelEvent,
} from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { DrivenList, DrivenRow } from "../../../ui/DrivenList";
import { HomeIcon } from "../../home-channels/icons";
import type { Strings } from "../../shared/i18n";
import type { HeaderMetrics, HostMenuItem } from "../types";
import { headerControls, headerLayout, headerSizes, listMetrics, ROW, type Rect } from "./layout";
import { ListRow, PinnedTile, SwipeStrip, TeammateRow, type ItemEvents, type Modifiers } from "./ListItems";
import { neighbor, placePinned, type ListItem, type ListModel, type TeammateItem } from "./model";
import { SWIPE_END_MS, swipeActions, swipeBy, swipeEnd, type SwipeAction, type SwipeState } from "./swipe";

/** Three looks of the same list (the gallery's variants); `messages` is the one the page uses. */
export type ListLook = "messages" | "accent" | "quiet";

export interface ConversationListProps {
  /** What the list shows (search and filter applied: list/model.ts). */
  model: ListModel;
  width: number;
  selected?: string;
  query: string;
  onQuery(query: string): void;
  unreadOnly: boolean;
  onUnreadOnly(on: boolean): void;
  strings: Strings;
  /** The window's traffic lights over the list's top-left (host-provided), or null. */
  windowControls: Rect | null;
  /** The owner keeps my pins and marks: Pin, Mark as Unread and the grid drags are offered. */
  canPin: boolean;
  onSelect(id: string): void;
  /** A plain click or Return: the conversation opens (its message box takes the keyboard). */
  onOpen(id: string): void;
  onSetPinned(id: string, pinned: boolean): void;
  /** The grid's whole new order after a drag (a row dropped in is pinned at its place). */
  onArrangePinned(order: string[]): void;
  onMarkRead(id: string): void;
  onMarkUnread(id: string): void;
  /** Delete Conversation… (absent: not offered). */
  onDelete?(id: string): void;
  /** The host's catalog items for a row (Chat Colors…, Group Info, Mute, Leave, a Chief's Usage). */
  hostMenu?(id: string): Promise<HostMenuItem[]>;
  onHostItem?(item: HostMenuItem): void;
  /** The New Message draft's row title, first under the grid, with its close x; absent: none. */
  draftTitle?: string;
  onSelectDraft?(): void;
  onCloseDraft?(): void;
  /** The quiet line under the list (Cloud conversations not reachable). */
  note?: string;
  /** Open Message Requests (none: no button). */
  requests?: number;
  onOpenRequests?(): void;
  look?: ListLook;
  /** The header's sizes at the sidebar's density and text size (absent: Compact, default text). */
  header?: HeaderMetrics;
  /** The header's band and its controls changed (the band's empty space moves the window). */
  onHeaderBand?(band: Rect, controls: Rect[]): void;
  /** A teammate with no DM yet was chosen (their participant id): the DM starts. */
  onStartTeammate?(person: string): void;
}

/** The draft row's id (the New Message page's). */
export const DRAFT_ROW = "home.newMessage";
const DRAG_THRESHOLD = 4;
const OVERSCAN = 600;
const SCROLL_QUANTUM = 64;
/** The search's "Teammates" header row. */
const SECTION_HEIGHT = 28;

interface Drag {
  id: string;
  fromGrid: boolean;
  /** The pointer in the scroller's content coordinates. */
  x: number;
  y: number;
  /** Where the tile would land in the grid, or null outside it. */
  index: number | null;
}

export function ConversationList(props: ConversationListProps) {
  const { model, width, selected, query, unreadOnly, strings, canPin, look = "messages" } = props;
  const { t, format } = strings;
  const metrics = useMemo(() => listMetrics(width), [width]);
  const [searchFocused, setSearchFocused] = useState(false);
  const sizes = useMemo(() => headerSizes(props.header), [props.header]);
  const header = headerLayout(width, searchFocused || query !== "", props.windowControls, unreadOnly, sizes);
  // The band and its controls go to the host only when they change.
  const bandKey = JSON.stringify([width, header.listTop, headerControls(header)]);
  const onHeaderBand = props.onHeaderBand;
  useEffect(() => {
    const [w, top, controls] = JSON.parse(bandKey) as [number, number, Rect[]];
    onHeaderBand?.({ x: 0, y: 0, width: w, height: top }, controls);
  }, [bandKey, onHeaderBand]);
  const scroller = useRef<HTMLDivElement | null>(null);
  const search = useRef<HTMLInputElement | null>(null);
  const [view, setView] = useState({ top: 0, height: 800 });
  const [drag, setDrag] = useState<Drag | null>(null);
  const pending = useRef<{ id: string; fromGrid: boolean; x: number; y: number; pointer: number } | null>(null);
  const suppressClick = useRef(false);
  const [menuFor, setMenuFor] = useState<string | undefined>();
  const [hostItems, setHostItems] = useState<ReadonlyMap<string, HostMenuItem[]>>(new Map());

  const byId = useMemo(() => {
    const map = new Map<string, ListItem>();
    for (const item of model.pinned) map.set(item.id, item);
    for (const item of model.rows) map.set(item.id, item);
    return map;
  }, [model]);

  // The grid as it shows: during a drag, with the dragged tile at its target (or out of the grid).
  const pinnedIds = useMemo(() => model.pinned.map((item) => item.id), [model]);
  const shownPinned =
    drag === null
      ? pinnedIds
      : drag.index !== null
        ? placePinned(pinnedIds, drag.id, drag.index)
        : pinnedIds.filter((id) => id !== drag.id);
  const pinnedHeight = metrics.pinnedHeight(shownPinned.length);
  const draft = props.draftTitle !== undefined;
  // The rows: the draft row first, then the conversations (a row dragged into the grid leaves them).
  const rows = drag && !drag.fromGrid && drag.index !== null ? model.rows.filter((r) => r.id !== drag.id) : model.rows;
  const rowStart = pinnedHeight + (draft ? metrics.rowHeight : 0);
  // The people with no DM yet come after the rows (a search's under their section's header).
  const people = model.people ?? [];
  const section = model.peopleSection && people.length > 0;
  const peopleStart = rowStart + rows.length * metrics.rowHeight + (section ? SECTION_HEIGHT : 0);
  const contentHeight = peopleStart + people.length * metrics.rowHeight;
  const first = Math.max(0, Math.floor((view.top - OVERSCAN - rowStart) / metrics.rowHeight));
  const last = Math.min(rows.length, Math.ceil((view.top + view.height + OVERSCAN - rowStart) / metrics.rowHeight));
  const firstPerson = Math.max(0, Math.floor((view.top - OVERSCAN - peopleStart) / metrics.rowHeight));
  const lastPerson = Math.min(
    people.length,
    Math.ceil((view.top + view.height + OVERSCAN - peopleStart) / metrics.rowHeight),
  );
  const selectedRow = selected === undefined ? -1 : rows.findIndex((row) => row.id === selected);

  // The visible window follows the scroll position in steps (a render per step, not per frame).
  useEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const read = () => {
      const top = Math.floor(element.scrollTop / SCROLL_QUANTUM) * SCROLL_QUANTUM;
      const height = element.clientHeight || 800;
      setView((old) => (old.top === top && old.height === height ? old : { top, height }));
    };
    read();
    element.addEventListener("scroll", read, { passive: true });
    const observer = new ResizeObserver(read);
    observer.observe(element);
    return () => {
      element.removeEventListener("scroll", read);
      observer.disconnect();
    };
  }, []);

  // The selection stays in view (Up and Down past the edge, a selection made elsewhere).
  useEffect(() => {
    const element = scroller.current;
    if (!element || selected === undefined) return;
    const tile = shownPinned.indexOf(selected);
    let box: { top: number; bottom: number } | undefined;
    if (tile >= 0) {
      const rect = metrics.tileRect(tile);
      box = { top: rect.y, bottom: rect.y + rect.height };
    } else if (selectedRow >= 0) {
      const top = rowStart + selectedRow * metrics.rowHeight;
      box = { top, bottom: top + metrics.rowHeight };
    }
    if (!box) return;
    if (box.top < element.scrollTop) element.scrollTop = box.top;
    else if (box.bottom > element.scrollTop + element.clientHeight)
      element.scrollTop = box.bottom - element.clientHeight;
    // Only a new selection scrolls (a drag or a width change leaves the scroll position alone).
  }, [selected]); // oxlint-disable-line react-hooks/exhaustive-deps

  // A row's swipe (swipe.ts): the wheel's horizontal steps move it; a quiet wheel ends the gesture.
  const [swipe, setSwipe] = useState<SwipeState | null>(null);
  // The row settling after a release (open, closed): it moves to its place with the rows' timing.
  const [settling, setSettling] = useState<string | null>(null);
  const swipeEndTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const swipeRef = useRef<SwipeState | null>(null);
  swipeRef.current = swipe;
  const actionsFor = (item: ListItem) => swipeActions(item.unread, canPin, !!props.onDelete);
  const runSwipe = (action: SwipeAction, id: string) => {
    setSettling(id);
    setSwipe(null);
    if (action === "delete") props.onDelete?.(id);
    else if (action === "read") props.onMarkRead(id);
    else props.onMarkUnread(id);
  };
  const endSwipe = () => {
    swipeEndTimer.current = undefined;
    const current = swipeRef.current;
    const item = current ? byId.get(current.id) : undefined;
    if (!current || !item) return setSwipe(null);
    const end = swipeEnd(current, width, actionsFor(item));
    setSettling(current.id);
    if (end.run) runSwipe(end.run, current.id);
    else setSwipe(end.state);
  };
  useEffect(() => () => clearTimeout(swipeEndTimer.current), []);
  const closeSwipe = () => {
    if (!swipeRef.current) return;
    clearTimeout(swipeEndTimer.current);
    swipeEndTimer.current = undefined;
    setSettling(swipeRef.current.id);
    setSwipe(null);
  };
  const onWheel = (event: ReactWheelEvent) => {
    const horizontal = Math.abs(event.deltaX) > Math.abs(event.deltaY);
    const current = swipeRef.current;
    if (!horizontal) {
      // A scroll closes an open row (not one still under the fingers).
      if (current && swipeEndTimer.current === undefined) closeSwipe();
      return;
    }
    const target = (event.target as HTMLElement).closest<HTMLElement>("[data-list-row]");
    const id = current && swipeEndTimer.current !== undefined ? current.id : target?.dataset.listRow;
    const item = id ? byId.get(id) : undefined;
    if (!item || metrics.compact || query.trim() !== "" || drag) return;
    const start = current?.id === item.id ? current : { id: item.id, offset: 0, open: false };
    setSettling(null);
    // Fingers to the right move the row right (the wheel's deltaX is the other way).
    setSwipe(swipeBy(start, -event.deltaX, width, actionsFor(item)));
    clearTimeout(swipeEndTimer.current);
    swipeEndTimer.current = setTimeout(endSwipe, SWIPE_END_MS);
  };

  const fetchMenu = (id: string) => {
    if (!props.hostMenu || id === DRAFT_ROW) return;
    void props.hostMenu(id).then((items) =>
      setHostItems((old) => {
        const next = new Map(old);
        next.set(id, items);
        return next;
      }),
    );
  };

  // A drag starts after the pointer moves a few points, and follows it until the button goes up.
  useEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const point = (event: PointerEvent) => {
      const box = element.getBoundingClientRect();
      return { x: event.clientX - box.left, y: event.clientY - box.top + element.scrollTop };
    };
    const target = (x: number, y: number, fromGrid: boolean, count: number) => {
      // The grid's area, and for a row also half a tile under it (a first pin into an empty grid).
      const bottom = metrics.pinnedHeight(count) + (fromGrid ? 0 : metrics.tileHeight / 2);
      return y >= 0 && y < Math.max(bottom, fromGrid ? 0 : metrics.tileHeight / 2)
        ? metrics.tileIndexAt(x, y, fromGrid ? count - 1 : count)
        : null;
    };
    // The listeners are added again after every render, so `drag` here is the current one.
    const move = (event: PointerEvent) => {
      const start = pending.current;
      if (!start || event.pointerId !== start.pointer) return;
      const at = point(event);
      if (!drag && Math.hypot(at.x - start.x, at.y - start.y) < DRAG_THRESHOLD) return;
      const count = pinnedIds.length + (start.fromGrid ? 0 : 1);
      // A row's lift opens no slot in the grid, so no row moves as a drag starts. The grid opens once the pointer is in
      // it, or moving up, half a row under it; then it stays open while the pointer is over its open area.
      const shut = metrics.pinnedHeight(pinnedIds.length);
      const opens = !!drag && (at.y < shut || (at.y < drag.y && at.y < shut + metrics.rowHeight / 2));
      const index = start.fromGrid || drag?.index != null || opens ? target(at.x, at.y, start.fromGrid, count) : null;
      setDrag({ id: start.id, fromGrid: start.fromGrid, x: at.x, y: at.y, index });
    };
    const up = (event: PointerEvent) => {
      const start = pending.current;
      if (!start || event.pointerId !== start.pointer) return;
      pending.current = null;
      if (!drag) return;
      suppressClick.current = true;
      setDrag(null);
      if (drag.index !== null) props.onArrangePinned(placePinned(pinnedIds, drag.id, drag.index));
      else if (drag.fromGrid) props.onSetPinned(drag.id, false);
    };
    const cancel = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || !pending.current) return;
      pending.current = null;
      setDrag(null);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
    window.addEventListener("keydown", cancel);
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      window.removeEventListener("keydown", cancel);
    };
  });

  const events: ItemEvents = {
    onClick(id: string, event: Modifiers) {
      if (suppressClick.current) {
        suppressClick.current = false;
        return;
      }
      if (id === DRAFT_ROW) {
        props.onSelectDraft?.();
        return;
      }
      props.onSelect(id);
      if (!event.metaKey && !event.shiftKey && !event.ctrlKey) props.onOpen(id);
      scroller.current?.focus({ preventScroll: true });
    },
    onPointerDown(id: string, fromGrid: boolean, event: ReactPointerEvent) {
      if (swipeRef.current) {
        // A press anywhere but on an action closes the open row (and is no click on it).
        if (swipeRef.current.id === id) suppressClick.current = true;
        closeSwipe();
        return;
      }
      if (event.button !== 0 || !canPin || id === DRAFT_ROW || query !== "" || unreadOnly) return;
      const element = scroller.current;
      if (!element) return;
      const box = element.getBoundingClientRect();
      pending.current = {
        id,
        fromGrid,
        x: event.clientX - box.left,
        y: event.clientY - box.top + element.scrollTop,
        pointer: event.pointerId,
      };
    },
    onHover: fetchMenu,
  };

  const onListKey = (event: ReactKeyboardEvent) => {
    if (event.target !== event.currentTarget) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next =
        selected === undefined
          ? event.key === "ArrowDown"
            ? (model.pinned[0] ?? model.rows[0])?.id
            : (model.rows.at(-1) ?? model.pinned.at(-1))?.id
          : neighbor(model, selected, event.key === "ArrowDown" ? 1 : -1);
      if (next) {
        props.onSelect(next);
        fetchMenu(next);
      }
    } else if (event.key === "Enter") {
      if (selected !== undefined && byId.has(selected)) {
        event.preventDefault();
        props.onOpen(selected);
      }
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
      event.preventDefault();
      search.current?.focus();
    }
    // A letter goes on to the page, which hands it to the message box (`followTyping`).
  };

  const onSearchKey = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      props.onQuery("");
      scroller.current?.focus();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      const first = model.pinned[0] ?? model.rows[0];
      if (first) props.onSelect(first.id);
      scroller.current?.focus();
    } else if (event.key === "Enter") {
      const first = model.pinned[0] ?? model.rows[0];
      if (first) {
        event.preventDefault();
        props.onSelect(first.id);
        props.onOpen(first.id);
      }
    }
  };

  // The row a menu opens for: the one under the pointer, else (Shift-F10) the selection.
  const onContextMenuCapture = (event: ReactMouseEvent) => {
    const row = (event.target as HTMLElement).closest<HTMLElement>("[data-list-row], [data-pinned-tile]");
    const id = row?.dataset.listRow ?? row?.dataset.pinnedTile ?? selected;
    setMenuFor(id === DRAFT_ROW ? undefined : id);
    if (id && id !== DRAFT_ROW && !hostItems.has(id)) fetchMenu(id);
  };
  const menuItem = menuFor ? byId.get(menuFor) : undefined;
  const menuItems = menuItem ? rowMenu(menuItem, props, hostItems.get(menuItem.id) ?? [], strings) : [];

  const filtered = query.trim() !== "" || unreadOnly;
  const empty = filtered && model.pinned.length === 0 && model.rows.length === 0 && people.length === 0;
  const startTeammate = (person: TeammateItem) => props.onStartTeammate?.(person.person.id);
  const swiped = swipe ? byId.get(swipe.id) : undefined;
  const swipedRow = swiped ? rows.findIndex((row) => row.id === swiped.id) : -1;
  const swipeLabels = {
    read: t("sidebar.menu.markRead"),
    unread: t("sidebar.menu.markUnread"),
    delete: t("sidebar.menu.delete"),
  };
  const tileFor = (id: string) => byId.get(id);
  const lifted = drag ? byId.get(drag.id) : undefined;

  return (
    <nav
      className={`hm-list look-${look}${metrics.compact ? " compact" : ""}`}
      aria-label={t("home.list.title")}
      style={
        {
          "--hm-header-text-step": `${sizes.textStep}px`,
          "--hm-chip-padding": `${sizes.chipPadding}px`,
        } as CSSProperties
      }
    >
      <div className="hm-header" style={{ height: header.listTop }}>
        {(header.search.width > 0 || !header.compact) && (
          <label
            className={`hm-search${searchFocused ? " focused" : ""}`}
            style={box(header.search)}
            onPointerDown={(event) => {
              if (event.target !== search.current) {
                event.preventDefault();
                search.current?.focus();
              }
            }}
          >
            <HomeIcon name="search" size={14} />
            <input
              ref={search}
              type="search"
              placeholder={t("sidebar.search")}
              aria-label={t("sidebar.search")}
              value={query}
              onChange={(event) => props.onQuery(event.target.value)}
              onFocus={() => setSearchFocused(true)}
              onBlur={() => setSearchFocused(false)}
              onKeyDown={onSearchKey}
            />
          </label>
        )}
        {header.compact && header.search.width === 0 && (
          // The avatar-only list keeps a hidden field so Command-F and type-to-search still reach it.
          <input
            ref={search}
            className="hm-search-hidden"
            tabIndex={-1}
            aria-hidden="true"
            value={query}
            onChange={(event) => props.onQuery(event.target.value)}
            onFocus={() => setSearchFocused(true)}
            onBlur={() => setSearchFocused(false)}
            onKeyDown={onSearchKey}
          />
        )}
        {header.searchIcon.width > 0 && (
          <button
            type="button"
            className="hm-circle"
            style={box(header.searchIcon)}
            aria-label={t("sidebar.search")}
            title={t("sidebar.search")}
            onClick={() => search.current?.focus()}
          >
            <HomeIcon name="search" size={14} />
          </button>
        )}
        {header.filter.width > 0 && (
          <button
            type="button"
            className={`hm-circle${unreadOnly ? " on" : ""}`}
            style={box(header.filter)}
            aria-pressed={unreadOnly}
            aria-label={t("sidebar.filter.unread")}
            title={t("sidebar.filter.unread")}
            onClick={() => props.onUnreadOnly(!unreadOnly)}
          >
            <FilterGlyph />
          </button>
        )}
        {header.filterChip.width > 0 && (
          <div className={`hm-chip-row${header.compact ? " centered" : ""}`} style={box(header.filterChip)}>
            <button
              type="button"
              className="hm-chip"
              title={t("home.list.filterChipHelp")}
              onClick={() => props.onUnreadOnly(false)}
            >
              <span>{t("sidebar.filter.unread")}</span>
              <HomeIcon name="close" size={12} />
            </button>
          </div>
        )}
      </div>
      <ContextMenu items={menuItems} className="hm-menu-host" targets="own">
        <DrivenList
          kind="listbox"
          label={t("home.list.title")}
          ref={scroller}
          className={`hm-scroller${drag ? " dragging" : ""}`}
          tabIndex={0}
          aria-activedescendant={selected !== undefined && byId.has(selected) ? `hm-item-${selected}` : undefined}
          onKeyDown={onListKey}
          onContextMenuCapture={onContextMenuCapture}
          onWheel={onWheel}
        >
          <div className="hm-content" style={{ height: contentHeight }}>
            {shownPinned.map((id, index) => {
              const item = tileFor(id);
              if (!item) return null;
              const rect = metrics.tileRect(index);
              const isLifted = drag?.id === id;
              return (
                <PinnedTile
                  key={id}
                  item={item}
                  x={isLifted ? drag.x - rect.width / 2 : rect.x}
                  y={isLifted ? drag.y - rect.height / 2 : rect.y}
                  width={rect.width}
                  height={rect.height}
                  avatar={metrics.pinAvatar}
                  compact={metrics.compact}
                  selected={id === selected}
                  events={events}
                  lifted={isLifted}
                />
              );
            })}
            {draft && (
              <DrivenRow
                kind="option"
                aria-selected={selected === DRAFT_ROW}
                data-list-row={DRAFT_ROW}
                className={`hm-row draft${metrics.compact ? " compact" : ""}${selected === DRAFT_ROW ? " selected" : ""}`}
                style={{ transform: `translateY(${pinnedHeight}px)`, height: metrics.rowHeight }}
                onPick={(event) => events.onClick(DRAFT_ROW, event)}
              >
                <span className="hm-row-head">
                  <span className="hm-row-name">{props.draftTitle}</span>
                </span>
                {props.onCloseDraft && (
                  <button
                    type="button"
                    className="hm-draft-close"
                    aria-label={t("home.compose.close")}
                    title={t("home.compose.close")}
                    onClick={(event) => {
                      event.stopPropagation();
                      props.onCloseDraft?.();
                    }}
                  >
                    <HomeIcon name="close" size={12} />
                  </button>
                )}
              </DrivenRow>
            )}
            {rows.slice(first, last).map((item, offset) => {
              const index = first + offset;
              const isLifted = drag?.id === item.id && !drag.fromGrid;
              return (
                <ListRow
                  key={item.id}
                  item={item}
                  top={isLifted ? drag.y - metrics.rowHeight / 2 : rowStart + index * metrics.rowHeight}
                  height={metrics.rowHeight}
                  selected={item.id === selected}
                  compact={metrics.compact}
                  avatar={metrics.compact ? metrics.compactAvatar : ROW.avatar}
                  separator={index < rows.length - 1 && index !== selectedRow && index + 1 !== selectedRow}
                  events={events}
                  dragging={isLifted}
                  swipeX={swipe?.id === item.id ? swipe.offset : 0}
                  settling={settling === item.id}
                />
              );
            })}
            {swipe && swiped && swipedRow >= 0 && swipe.offset !== 0 && (
              <SwipeStrip
                top={rowStart + swipedRow * metrics.rowHeight}
                height={metrics.rowHeight}
                offset={swipe.offset}
                open={swipe.open}
                settling={settling === swipe.id}
                actions={swipe.offset > 0 ? actionsFor(swiped).leading : actionsFor(swiped).trailing}
                labels={swipeLabels}
                onAction={(action) => runSwipe(action, swiped.id)}
              />
            )}
            {section && (
              <div
                className="hm-section-head"
                role="presentation"
                style={{ transform: `translateY(${peopleStart - SECTION_HEIGHT}px)`, height: SECTION_HEIGHT }}
              >
                {t("home.list.teammates")}
              </div>
            )}
            {people.slice(firstPerson, lastPerson).map((person, offset) => (
              <TeammateRow
                key={person.id}
                item={person}
                top={peopleStart + (firstPerson + offset) * metrics.rowHeight}
                height={metrics.rowHeight}
                compact={metrics.compact}
                avatar={metrics.compact ? metrics.compactAvatar : ROW.avatar}
                onPick={startTeammate}
              />
            ))}
            {lifted && !drag?.fromGrid && drag?.index !== null && (
              <PinnedTile
                item={lifted}
                x={(drag?.x ?? 0) - metrics.tileWidth / 2}
                y={(drag?.y ?? 0) - metrics.tileHeight / 2}
                width={metrics.tileWidth}
                height={metrics.tileHeight}
                avatar={metrics.pinAvatar}
                compact={metrics.compact}
                selected={false}
                events={events}
                lifted
              />
            )}
          </div>
          {empty && (
            <div className="hm-empty" style={{ top: 0 }}>
              <p>{unreadOnly && query.trim() === "" ? t("sidebar.noUnread") : t("sidebar.noResults")}</p>
              {unreadOnly && query.trim() === "" && (
                <button type="button" className="hm-show-all" onClick={() => props.onUnreadOnly(false)}>
                  {t("sidebar.showAll")}
                </button>
              )}
            </div>
          )}
        </DrivenList>
      </ContextMenu>
      {(props.note || (props.requests ?? 0) > 0) && (
        <footer className="hm-footer">
          {(props.requests ?? 0) > 0 && (
            <button type="button" className="hm-requests" onClick={props.onOpenRequests}>
              {format("home.requests.bar", String(props.requests))}
            </button>
          )}
          {props.note && <p className="hm-note">{props.note}</p>}
        </footer>
      )}
    </nav>
  );
}

/** A row's menu: the list's own items, then the host's, then Delete Conversation…. */
export function rowMenu(
  item: ListItem,
  props: Pick<
    ConversationListProps,
    "canPin" | "onSetPinned" | "onMarkRead" | "onMarkUnread" | "onDelete" | "onHostItem"
  >,
  host: readonly HostMenuItem[],
  strings: Strings,
): ContextMenuItem[] {
  const { t } = strings;
  const items: ContextMenuItem[] = [];
  if (props.canPin)
    items.push({
      id: "pin",
      label: t(item.pinned ? "sidebar.menu.unpin" : "sidebar.menu.pin"),
      onSelect: () => props.onSetPinned(item.id, !item.pinned),
    });
  if (item.unread)
    items.push({ id: "read", label: t("sidebar.menu.markRead"), onSelect: () => props.onMarkRead(item.id) });
  else if (props.canPin)
    items.push({ id: "unread", label: t("sidebar.menu.markUnread"), onSelect: () => props.onMarkUnread(item.id) });
  host.forEach((entry, index) =>
    items.push({
      id: `host:${entry.id}`,
      label: entry.title,
      ...(entry.destructive ? { destructive: true } : {}),
      ...(entry.checked !== undefined ? { checked: entry.checked } : {}),
      separatorBefore: (index === 0 && items.length > 0) || entry.separatorBefore === true,
      onSelect: () => props.onHostItem?.(entry),
    }),
  );
  if (props.onDelete) {
    const onDelete = props.onDelete;
    items.push({
      id: "delete",
      label: t("sidebar.menu.delete"),
      separatorBefore: items.length > 0,
      onSelect: () => onDelete(item.id),
    });
  }
  return items;
}

function box(rect: Rect) {
  return { transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.width, height: rect.height };
}

/** Messages' filter glyph: three lines, each shorter. */
function FilterGlyph() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <path d="M3.5 6h13M6 10h8M8.5 14h3" />
    </svg>
  );
}
