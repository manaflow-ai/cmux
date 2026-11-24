// The History page (plans/cmux-next/react-pages.md 2.4; behavior of the Swift page in
// plans/cmux-next/history.md 5.1). State lives in `HistoryStore`; this file only renders it and
// turns plain keys and clicks into store intents. Cmd/Ctrl chords never reach page handlers.
// The list is windowed: up to PAGE_LIMIT entries (and the page asks again), but only the headers and
// rows near the viewport are mounted, plus the selected and the focused row so Up/Down and keys never
// lose them. Rows are memoized on their entry, selection and offset, so a selection draws two rows,
// not the list.
import {
  useRef,
  useState,
  useSyncExternalStore,
  type KeyboardEvent,
  type MouseEvent,
  memo,
  useCallback,
  useLayoutEffect,
  useMemo,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../../agent-session/acpmux/stableHandlers";
import { PageMenu, type PageMenuItem } from "../shared/PageMenu";
import type { Strings } from "../shared/i18n";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../ui/lasting";
import { isEditableTarget, type KeyStyle, type ShortcutLayout } from "../../ui/keyStyle";
import { useListKeys } from "../../ui/useListKeys";
import { CookieBackupsPanel } from "./CookieBackups";
import { KindIcon } from "./KindIcon";
import {
  BadgeLabel,
  canOpen,
  FilterLabel,
  groupTitle,
  GroupingLabel,
  HISTORY_FILTERS,
  HISTORY_GROUPINGS,
  menuItems,
  RangeLabel,
  rowBadge,
  rowDetail,
  rowTime,
  type ListItem,
  listModel,
  moved,
  target,
} from "./model";
import type { HistoryStore } from "./store";
import { HISTORY_RANGES, type HistoryEntry } from "./types";
import { focusRoute } from "../../ui/focusRoute";

type OpenMenu = { session: number; x: number; y: number; items: PageMenuItem[]; returnFocus: HTMLElement | null };

/** Row and group-header heights before the first of their kind is measured (styles.css). */
const ROW_ESTIMATE = 36;
const HEADER_ESTIMATE = 36;

/** The kinds of item whose heights differ: a group header, a row with a detail line, a row without. */
type SizeKind = "group" | "detail" | "plain";
const rowSize = (entry: HistoryEntry): SizeKind => (rowDetail(entry) ? "detail" : "plain");
const itemSize = (item: ListItem | undefined): SizeKind =>
  item?.kind === "group" ? "group" : item ? rowSize(item.entry) : "plain";
/** About one viewport of rows above and below the visible ones. */
const OVERSCAN = 20;

// A stable callback ref: React calls it only when the node mounts.
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

/** A plain key: no Cmd, Ctrl or Option (those belong to the app's key dispatcher). */
function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

export function HistoryPage({
  store,
  strings,
  now = Date.now,
  keyStyle,
  shortcutLayout,
}: {
  store: HistoryStore;
  strings: Strings;
  now?: () => number;
  /** `app.keyStyle` and `app.shortcutLayout`; without them the page's own (Standard). */
  keyStyle?: KeyStyle;
  shortcutLayout?: ShortcutLayout;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  // Even when two native menus open before the first reply, each owns its own actions.
  const menuSession = useRef(0);
  const { t, language } = strings;
  // A lost history owner keeps the rows it had and says so only once it lasts (a launch, a daemon
  // restart: the store re-reads once the link is back), as a corner mark that takes no room.
  const down = snap.connection === "disconnected";
  const downLasting = useConnectionQuiet(down);
  const list = useMemo(() => listModel(snap.groups), [snap.groups]);
  const selectedItem = snap.selection === undefined ? -1 : (list.place.get(snap.selection)?.item ?? -1);
  // The row that holds focus (a click focuses it) stays mounted too, however far Up/Down move.
  const [focusedRow, setFocusedRow] = useState<string | undefined>(undefined);
  const focusedItem = focusedRow === undefined ? -1 : (list.place.get(focusedRow)?.item ?? -1);
  const scroller = useRef<HTMLDivElement | null>(null);
  // One function per list: TanStack measures every item again when it changes.
  const itemKey = useCallback(
    (index: number) => {
      const item = list.items[index]!;
      return item.kind === "group" ? `group:${item.group.id}` : item.entry.id;
    },
    [list],
  );
  // The first mounted item of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N items again whenever a measure differs.
  const sizes = useRef(new Map<SizeKind, number>());
  const virtualizer = useVirtualizer({
    count: list.items.length,
    getScrollElement: () => scroller.current,
    estimateSize: (index) => {
      const kind = itemSize(list.items[index]);
      return sizes.current.get(kind) ?? (kind === "group" ? HEADER_ESTIMATE : ROW_ESTIMATE);
    },
    getItemKey: itemKey,
    overscan: OVERSCAN,
    // The list's own top and bottom space (styles.css pads only its sides).
    paddingStart: 4,
    paddingEnd: 18,
    // The selected and the focused rows stay mounted: Up/Down move from one, keys arrive at the other.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      for (const kept of [selectedItem, focusedItem])
        if (kept >= 0 && !indexes.includes(kept)) {
          indexes.push(kept);
          indexes.sort((a, b) => a - b);
        }
      return indexes;
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      const kind = node?.dataset.size as SizeKind | undefined;
      if (node && kind && !sizes.current.has(kind) && node.offsetHeight > 0) sizes.current.set(kind, node.offsetHeight);
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );
  // A new selection, or a new grouping, scrolls the selected row into view (each row did this as it
  // mounted selected when every row was mounted).
  const revealed = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const key = snap.selection === undefined ? undefined : `${snap.grouping}:${snap.selection}`;
    if (key === revealed.current) return;
    revealed.current = key;
    if (selectedItem >= 0) virtualizer.scrollToIndex(selectedItem, { align: "auto" });
  });

  const open = (entry: HistoryEntry | undefined, newTab = false) => {
    if (entry && canOpen(entry)) void store.open(entry, newTab);
  };

  // `app.keyStyle` (the host's values as props; the page gets no `display` event): in the list
  // Vim's j/k, gg/G, Ctrl-D/U and l, Emacs' alike, as the arrows and Return; / or Ctrl-S go to the
  // search field, whose Esc (Vim) or Ctrl-G (Emacs) gives the keyboard back to the list, and whose
  // Ctrl-N/P (Emacs) move the list as its arrows do.
  const styleKeys = useListKeys({
    style: keyStyle,
    layout: shortcutLayout,
    onCommand: (command, event) => {
      const inSearch = isEditableTarget(event.target);
      const doc = (event.target as Node).ownerDocument ?? document;
      const move = (offset: number) => store.select(moveSelection(flat, snap.selection, offset));
      if (command === "list.next") move(1);
      else if (command === "list.previous") move(-1);
      else if (command === "list.leave") {
        if (!inSearch) return false;
        focusRoute(doc.getElementById("history-list"), "person", "key style list key");
      } else if (inSearch) return false;
      else if (command === "list.first") move(-flat.length);
      else if (command === "list.last") move(flat.length);
      else if (command === "list.pageDown") move(10);
      else if (command === "list.pageUp") move(-10);
      else if (command === "list.open") open(returnTarget(flat, snap.selection));
      else if (command === "list.search")
        focusRoute(doc.querySelector<HTMLInputElement>(".history-search"), "person", "key style list key");
      else return false;
    },
  });

  const arrowKeys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "ArrowDown") store.select(moved(list, snap.selection, 1));
    else if (event.key === "ArrowUp") store.select(moved(list, snap.selection, -1));
    else if (event.key === "Enter") open(target(list, snap.selection));
    else return;
    event.preventDefault();
  };

  const listKeys = (event: KeyboardEvent) => {
    styleKeys(event);
    if (!event.defaultPrevented) arrowKeys(event);
  };

  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    styleKeys(event);
    if (event.defaultPrevented) return;
    if (plain(event) && event.key === "Escape" && snap.text) {
      store.setText("");
      event.preventDefault();
      return;
    }
    arrowKeys(event);
  };

  const rowMenu = (entry: HistoryEntry, event: MouseEvent) => {
    event.preventDefault();
    store.select(entry.id);
    const items: PageMenuItem[] = menuItems(entry).map((item, index) => ({
      id: `${index}`,
      label: t(item.action.label),
      destructive: item.destructive,
      separatorBefore: item.separatorBefore,
      disabled: item.action.kind === "open" && !canOpen(entry),
      run: () => {
        const action = item.action;
        if (action.kind === "open") open(entry, action.newTab);
        else if (action.kind === "copy") void store.copy(action.text);
        else if (action.kind === "removeSite") void store.removeSite(entry);
        else void store.remove(entry);
      },
    }));
    setMenu({
      session: ++menuSession.current,
      x: event.clientX,
      y: event.clientY,
      items,
      returnFocus: event.currentTarget instanceof HTMLElement ? event.currentTarget : null,
    });
  };

  // One function per handler for every render: a memo row draws again only when its own props change.
  const rowHandlers = useStableHandlers({
    onSelect: (entry: HistoryEntry) => store.select(entry.id),
    onOpen: (entry: HistoryEntry) => open(entry),
    onMenu: rowMenu,
  });

  const headerMenu = (event: MouseEvent<HTMLButtonElement>, items: PageMenuItem[]) => {
    const rect = event.currentTarget.getBoundingClientRect();
    setMenu({
      session: ++menuSession.current,
      x: rect.left,
      y: rect.bottom + 4,
      items,
      returnFocus: event.currentTarget,
    });
  };

  const groupingItems = (): PageMenuItem[] =>
    HISTORY_GROUPINGS.map((grouping) => ({
      id: grouping,
      label: t(GroupingLabel[grouping]),
      run: () => store.setGrouping(grouping),
    }));

  const rangeItems = (): PageMenuItem[] =>
    HISTORY_RANGES.map((range) => ({
      id: range,
      label: t(RangeLabel[range]),
      run: () => store.setRange(range),
    }));

  const clearItems = (): PageMenuItem[] =>
    HISTORY_RANGES.map((range) => ({
      id: range,
      label: t(RangeLabel[range]),
      destructive: true,
      run: () => void store.clear(range),
    }));

  return (
    <div className="history-page">
      <header className="history-header">
        <div className="history-title-row">
          <h1 className="history-title">{t("page.title")}</h1>
          <div className="history-title-actions">
            {/* How far back the list reaches; the search's `since:` and `before:` narrow it further. */}
            <button
              type="button"
              className={`history-menu-button history-range${snap.range === "all" ? "" : " selected"}`}
              // A range or a search typed while the link is down is kept; the reconnect's read uses it.
              onClick={(event) => headerMenu(event, rangeItems())}
            >
              {t(RangeLabel[snap.range])}
            </button>
            <button
              type="button"
              className="history-menu-button"
              onClick={(event) => headerMenu(event, groupingItems())}
            >
              {t("page.groupBy")}
            </button>
            <button type="button" className="history-menu-button" onClick={() => void store.showCookieBackups()}>
              {t("page.cookieBackups")}
            </button>
            <button
              type="button"
              className="history-menu-button"
              disabled={snap.connection === "disconnected"}
              onClick={(event) => headerMenu(event, clearItems())}
            >
              {t("page.clear")}
            </button>
          </div>
        </div>
        <input
          className="history-search"
          type="search"
          placeholder={t("page.search")}
          aria-label={t("page.search")}
          value={snap.text}
          // Stays live while the link comes back (Leo, 2026-11-24 11:57Z): the reconnect reads what was typed.
          ref={focusOnMount}
          onChange={(event) => store.setText(event.target.value)}
          onKeyDown={searchKeys}
          aria-controls="history-list"
        />
        <div className="history-chips" role="tablist">
          {HISTORY_FILTERS.map((filter) => (
            <button
              key={filter}
              type="button"
              role="tab"
              aria-selected={snap.filter === filter}
              className={`history-chip${snap.filter === filter ? " selected" : ""}`}
              onClick={() => store.setFilter(filter)}
            >
              {t(FilterLabel[filter])}
            </button>
          ))}
        </div>
      </header>
      {/* A lost host is said once, below, in the page's own words. */}
      {snap.error && snap.connection !== "disconnected" ? (
        <p className="history-error" role="alert">
          {snap.error}
        </p>
      ) : null}
      {/* The owner's list is not complete yet: the rows that came stay, and the page asks again by itself. */}
      {snap.pending && !down && snap.groups.length > 0 ? (
        <output className="history-pending">{t("page.stillLoading")}</output>
      ) : null}
      {downLasting ? <ConnectionChip text={t("page.disconnected")} /> : null}
      {down && snap.groups.length === 0 ? (
        // Nothing read yet and the link is down: blank, and no false "No history" either.
        <div className="history-empty" />
      ) : snap.groups.length === 0 && snap.pending ? (
        // A list that is not complete is never "No history": the page says so (a status region, as the
        // line above the rows is) and asks again by itself.
        <output className="history-empty">{t("page.stillLoading")}</output>
      ) : snap.groups.length === 0 ? (
        <div className="history-empty">{snap.loading ? "" : t(snap.text ? "page.emptySearch" : "page.empty")}</div>
      ) : (
        <div
          id="history-list"
          ref={scroller}
          className="history-list"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="listbox"
          tabIndex={0}
          onKeyDown={listKeys}
          onFocus={(event) => setFocusedRow((event.target as HTMLElement).dataset.entry)}
          onBlur={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget)) setFocusedRow(undefined);
          }}
        >
          <div className="history-list-space" style={{ height: virtualizer.getTotalSize() }}>
            {virtualizer.getVirtualItems().map(({ index, start }) => {
              const item = list.items[index]!;
              return item.kind === "group" ? (
                <GroupHeader
                  key={`group:${item.group.id}`}
                  index={index}
                  top={start}
                  title={groupTitle(item.group, snap.grouping, t, language, now())}
                  measure={measure}
                />
              ) : (
                <HistoryRow
                  key={item.entry.id}
                  index={index}
                  top={start}
                  entry={item.entry}
                  position={item.row + 1}
                  count={list.entries.length}
                  selected={item.entry.id === snap.selection}
                  language={language}
                  t={t}
                  measure={measure}
                  {...rowHandlers}
                />
              );
            })}
          </div>
        </div>
      )}
      {snap.cookieBackups.open && <CookieBackupsPanel store={store} state={snap.cookieBackups} strings={strings} />}
      {menu && (
        <PageMenu
          key={menu.session}
          x={menu.x}
          y={menu.y}
          items={menu.items}
          returnFocus={menu.returnFocus}
          onClose={() => setMenu(null)}
        />
      )}
    </div>
  );
}

/** Where a windowed item sits: its index (TanStack measures it by `data-index`) and offset. */
interface Placed {
  index: number;
  top: number;
  measure: (element: HTMLElement | null) => void;
}

const GroupHeader = memo(function GroupHeader({ index, top, title, measure }: Placed & { title: string }) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="group"
      className="history-group"
      style={{ transform: `translateY(${top}px)` }}
    >
      <h2 className="history-group-title">{title}</h2>
    </div>
  );
});

interface RowProps extends Placed {
  entry: HistoryEntry;
  /** 1-based place among every entry, and their count: the screen reader's "3 of 1000". */
  position: number;
  count: number;
  selected: boolean;
  language: string;
  t: Strings["t"];
  onSelect: (entry: HistoryEntry) => void;
  onOpen: (entry: HistoryEntry) => void;
  onMenu: (entry: HistoryEntry, event: MouseEvent) => void;
}

const HistoryRow = memo(function HistoryRow({
  index,
  top,
  measure,
  entry,
  position,
  count,
  selected,
  language,
  t,
  onSelect,
  onOpen,
  onMenu,
}: RowProps) {
  const detail = rowDetail(entry);
  const badge = rowBadge(entry);
  return (
    // The listbox owns Up/Down; a row takes Return when it has focus itself.
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="option"
      tabIndex={-1}
      aria-selected={selected}
      aria-disabled={entry.available ? undefined : true}
      aria-posinset={position}
      aria-setsize={count}
      className={`history-row${selected ? " selected" : ""}${entry.available ? "" : " unavailable"}`}
      ref={measure}
      data-index={index}
      data-size={rowSize(entry)}
      data-entry={entry.id}
      style={{ transform: `translateY(${top}px)` }}
      onClick={() => onSelect(entry)}
      onDoubleClick={() => onOpen(entry)}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || event.metaKey || event.ctrlKey || event.altKey) return;
        event.preventDefault();
        event.stopPropagation();
        onOpen(entry);
      }}
      onContextMenu={(event) => onMenu(entry, event)}
    >
      <span className="history-row-icon">
        <KindIcon kind={entry.kind} />
      </span>
      <span className="history-row-text">
        <span className="history-row-title">{entry.title}</span>
        {detail && <span className="history-row-detail">{detail}</span>}
      </span>
      {badge && <span className="history-row-badge">{t(BadgeLabel[badge])}</span>}
      <span className="history-row-time">{rowTime(entry, language)}</span>
    </div>
  );
});
