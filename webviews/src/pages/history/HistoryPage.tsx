// The History page (plans/cmux-next/react-pages.md 2.4; behavior of the Swift page in
// plans/cmux-next/history.md 5.1). State lives in `HistoryStore`; this file only renders it and
// turns plain keys and clicks into store intents. Cmd/Ctrl chords never reach page handlers.
import { useState, useSyncExternalStore, type KeyboardEvent, type MouseEvent } from "react";
import { PageMenu, type PageMenuItem } from "../shared/PageMenu";
import type { Strings } from "../shared/i18n";
import { KindIcon } from "./KindIcon";
import {
  BadgeLabel,
  canOpen,
  FilterLabel,
  flatten,
  groupTitle,
  GroupingLabel,
  HISTORY_FILTERS,
  HISTORY_GROUPINGS,
  menuItems,
  moveSelection,
  RangeLabel,
  returnTarget,
  rowBadge,
  rowDetail,
  rowTime,
} from "./model";
import type { HistoryStore } from "./store";
import { HISTORY_RANGES, type HistoryEntry } from "./types";

type OpenMenu = { x: number; y: number; items: PageMenuItem[]; returnFocus: HTMLElement | null };

// Stable callback refs: React calls them only when the node mounts (or the ref is attached).
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();
const revealOnSelect = (node: HTMLDivElement | null) => node?.scrollIntoView({ block: "nearest" });

/** A plain key: no Cmd, Ctrl or Option (those belong to the app's key dispatcher). */
function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

export function HistoryPage({
  store,
  strings,
  now = Date.now,
}: {
  store: HistoryStore;
  strings: Strings;
  now?: () => number;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const { t, language } = strings;
  const flat = flatten(snap.groups);

  const open = (entry: HistoryEntry | undefined, newTab = false) => {
    if (entry && canOpen(entry)) void store.open(entry, newTab);
  };

  const listKeys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "ArrowDown") store.select(moveSelection(flat, snap.selection, 1));
    else if (event.key === "ArrowUp") store.select(moveSelection(flat, snap.selection, -1));
    else if (event.key === "Enter") open(returnTarget(flat, snap.selection));
    else return;
    event.preventDefault();
  };

  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (plain(event) && event.key === "Escape" && snap.text) {
      store.setText("");
      event.preventDefault();
      return;
    }
    listKeys(event);
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
      x: event.clientX,
      y: event.clientY,
      items,
      returnFocus: event.currentTarget instanceof HTMLElement ? event.currentTarget : null,
    });
  };

  const headerMenu = (event: MouseEvent<HTMLButtonElement>, items: PageMenuItem[]) => {
    const rect = event.currentTarget.getBoundingClientRect();
    setMenu({ x: rect.left, y: rect.bottom + 4, items, returnFocus: event.currentTarget });
  };

  const groupingItems = (): PageMenuItem[] =>
    HISTORY_GROUPINGS.map((grouping) => ({
      id: grouping,
      label: t(GroupingLabel[grouping]),
      run: () => store.setGrouping(grouping),
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
            <button
              type="button"
              className="history-menu-button"
              onClick={(event) => headerMenu(event, groupingItems())}
            >
              {t("page.groupBy")}
            </button>
            <button type="button" className="history-menu-button" onClick={(event) => headerMenu(event, clearItems())}>
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
          disabled={snap.connection === "disconnected"}
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
      {snap.connection === "disconnected" ? (
        <div className="history-empty">{t("page.disconnected")}</div>
      ) : snap.groups.length === 0 ? (
        <div className="history-empty">{snap.loading ? "" : t(snap.text ? "page.emptySearch" : "page.empty")}</div>
      ) : (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div id="history-list" className="history-list" role="listbox" tabIndex={0} onKeyDown={listKeys}>
          {snap.groups.map((group) => (
            <section
              key={group.id}
              className="history-group"
              aria-label={groupTitle(group, snap.grouping, t, language, now())}
            >
              <h2 className="history-group-title">{groupTitle(group, snap.grouping, t, language, now())}</h2>
              {group.entries.map((entry) => (
                <HistoryRow
                  key={entry.id}
                  entry={entry}
                  selected={entry.id === snap.selection}
                  badge={rowBadge(entry)}
                  badgeText={(badge) => t(BadgeLabel[badge])}
                  language={language}
                  onSelect={() => store.select(entry.id)}
                  onOpen={() => open(entry)}
                  onMenu={(event) => rowMenu(entry, event)}
                />
              ))}
            </section>
          ))}
        </div>
      )}
      {menu && (
        <PageMenu
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

interface RowProps {
  entry: HistoryEntry;
  selected: boolean;
  badge: ReturnType<typeof rowBadge>;
  badgeText: (badge: NonNullable<ReturnType<typeof rowBadge>>) => string;
  language: string;
  onSelect: () => void;
  onOpen: () => void;
  onMenu: (event: MouseEvent) => void;
}

function HistoryRow({ entry, selected, badge, badgeText, language, onSelect, onOpen, onMenu }: RowProps) {
  const detail = rowDetail(entry);
  return (
    // The listbox owns Up/Down; a row takes Return when it has focus itself.
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="option"
      tabIndex={-1}
      aria-selected={selected}
      className={`history-row${selected ? " selected" : ""}${entry.available ? "" : " unavailable"}`}
      ref={selected ? revealOnSelect : undefined}
      onClick={onSelect}
      onDoubleClick={onOpen}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || event.metaKey || event.ctrlKey || event.altKey) return;
        event.preventDefault();
        event.stopPropagation();
        onOpen();
      }}
      onContextMenu={onMenu}
    >
      <span className="history-row-icon">
        <KindIcon kind={entry.kind} />
      </span>
      <span className="history-row-text">
        <span className="history-row-title">{entry.title}</span>
        {detail && <span className="history-row-detail">{detail}</span>}
      </span>
      {badge && <span className="history-row-badge">{badgeText(badge)}</span>}
      <span className="history-row-time">{rowTime(entry, language)}</span>
    </div>
  );
}
