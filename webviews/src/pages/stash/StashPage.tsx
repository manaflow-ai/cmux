// The Stashed Tabs page (a OneTab of cmux's own): stashed groups, newest first, each dated and
// named after its workspace, one compact line per page or workspace. A row's click restores it; its
// menu (a right-click, or Shift-F10 / the context-menu key on the focused row) deletes it behind the
// app's Undo toast. A row carries no destructive control of its own; a group's header shows Restore
// All only, and its menu (the same right-click or keys on Restore All) holds the rest. State lives in `StashStore`; this file renders
// it and turns plain keys and clicks into store intents. Cmd/Ctrl chords never reach it.
// The list is windowed: only the group headers and rows near the viewport are mounted, plus the
// focused one and the one whose menu is open. Rows are memoized on their member and offset with
// stable handlers, so a focus, a scroll step or a reply that changes one member draws only its rows.
import {
  memo,
  useCallback,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type FocusEvent,
  type KeyboardEvent,
  type MouseEvent,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../../agent-session/acpmux/stableHandlers";
import { PageMenu, pageMenuKey, type PageMenuItem } from "../shared/PageMenu";
import type { Strings } from "../shared/i18n";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../ui/lasting";
import {
  isWorkspace,
  matchGroups,
  memberHost,
  memberTitle,
  type StashItem,
  stashItemKey,
  stashList,
  workspaceTabs,
} from "./model";
import type { StashNotice, StashStore } from "./store";
import type { StashGroup, StashMember } from "./types";
import { intl } from "../../ui/intl";
import { WithFacts } from "../../agent-session/acpmux/chips/FactsHoverCard";

/** Row and group-header heights before the first of their kind is measured (styles.css). */
const ROW_ESTIMATE = 28;
const HEADER_ESTIMATE = 40;
/** About one viewport of rows above and below the visible ones. */
const OVERSCAN = 24;
type SizeKind = "group" | "row";
const itemSize = (item: StashItem | undefined): SizeKind => (item?.kind === "group" ? "group" : "row");

type OpenMenu = {
  session: number;
  x: number;
  y: number;
  items: PageMenuItem[];
  returnFocus: HTMLElement | null;
  /** The item the menu acts on: it stays mounted while the menu is open. */
  key: string;
};

const ICONS = {
  // Globe: circle, equator, meridian (the History page's page glyph).
  page: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM1.75 8h12.5M8 1.75c1.9 1.8 2.75 3.9 2.75 6.25S9.9 12.45 8 14.25C6.1 12.45 5.25 10.35 5.25 8S6.1 3.55 8 1.75Z",
  // A window with a sidebar: a workspace.
  workspace: "M2.25 3.25h11.5v9.5H2.25ZM5.75 3.25v9.5",
};

function Glyph({ path }: { path: string }) {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={path}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function noticeText(notice: StashNotice, strings: Strings): string {
  switch (notice.kind) {
    case "error":
      return notice.message;
    case "nothingToImport":
      return strings.t("stash.import.nothing");
    case "imported":
      return strings.format("stash.import.result", `${notice.imported}`, `${notice.skipped}`);
  }
}

export function StashPage({ store, strings }: { store: StashStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const menuSession = useRef(0);
  const { t, language } = strings;
  const down = snap.connection === "disconnected";
  const downLasting = useConnectionQuiet(down);
  const shown = useMemo(() => matchGroups(snap.groups, snap.query), [snap.groups, snap.query]);
  const list = useMemo(() => stashList(shown, snap.groups), [shown, snap.groups]);
  const time = useMemo(() => intl.DateTimeFormat(language, { timeStyle: "short" }), [language]);
  const date = useMemo(() => intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }), [language]);
  const count = useMemo(() => intl.NumberFormat(language), [language]);
  const off = snap.busy || down;

  // The item that holds focus stays mounted however far the list scrolls, and so does the one whose
  // menu is open (the menu gives focus back to it).
  const [focusedKey, setFocusedKey] = useState<string | undefined>(undefined);
  const focusedItem = focusedKey === undefined ? -1 : (list.place.get(focusedKey) ?? -1);
  const menuItem = menu ? (list.place.get(menu.key) ?? -1) : -1;
  const [scroller, setScroller] = useState<HTMLDivElement | null>(null);
  // One function per list: TanStack measures every item again when it changes.
  const itemKey = useCallback((index: number) => stashItemKey(list.items[index]!), [list]);
  // The first mounted item of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N items again whenever a measure differs.
  const sizes = useRef(new Map<SizeKind, number>());
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so the stash list stays uncompiled on purpose; it needs a stable getItemKey (so one changed group does not re-measure all N items) and keeps two rows mounted (the focused one and the one whose menu is open), and ui/VirtualList keys items by index and keeps only one active row, so ui/VirtualList does not fit.
  const virtualizer = useVirtualizer({
    count: list.items.length,
    getScrollElement: () => scroller,
    estimateSize: (index) => {
      const kind = itemSize(list.items[index]);
      return sizes.current.get(kind) ?? (kind === "group" ? HEADER_ESTIMATE : ROW_ESTIMATE);
    },
    getItemKey: itemKey,
    overscan: OVERSCAN,
    // The list's own top and bottom space (styles.css pads only its sides).
    paddingStart: 4,
    paddingEnd: 16,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      for (const kept of [focusedItem, menuItem])
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

  const showMenu = (key: string, x: number, y: number, returnFocus: HTMLElement | null, items: PageMenuItem[]) =>
    setMenu({ session: ++menuSession.current, x, y, items, returnFocus, key });
  const openMenu = (key: string, event: MouseEvent, items: PageMenuItem[]) => {
    event.preventDefault();
    showMenu(
      key,
      event.clientX,
      event.clientY,
      event.currentTarget instanceof HTMLElement ? event.currentTarget : null,
      items,
    );
  };
  const keyMenu = (key: string, event: KeyboardEvent, items: () => PageMenuItem[]) => {
    const at = pageMenuKey(event);
    if (at) showMenu(key, at.x, at.y, at.returnFocus, items());
  };

  const groupItems = (group: StashGroup): PageMenuItem[] => [
    { id: "restore", label: t("stash.restoreAll"), run: () => void store.restore(group) },
    { id: "new", label: t("stash.restoreInNewWorkspace"), run: () => void store.restore(group, undefined, true) },
    {
      id: "delete",
      label: t("stash.deleteGroup"),
      destructive: true,
      separatorBefore: true,
      run: () => void store.delete(group),
    },
  ];

  const memberItems = (group: StashGroup, member: StashMember): PageMenuItem[] => [
    { id: "restore", label: t("stash.restore"), run: () => void store.restore(group, [member]) },
    {
      id: "delete",
      label: t("stash.delete"),
      destructive: true,
      separatorBefore: true,
      run: () => void store.delete(group, member),
    },
  ];

  // Restore All and Delete Group take the whole group, not only the members a search shows: the
  // handlers find it by id in the list's map, so a row holds only its own stash's id.
  const whole = (stash: string) => list.wholes.get(stash);
  // One function per handler for every render: a memo row draws again only when its own props change.
  const handlers = useStableHandlers({
    onRestoreAll: (stash: string) => {
      const group = whole(stash);
      if (group) void store.restore(group);
    },
    onGroupMenu: (stash: string, event: MouseEvent) => {
      const group = whole(stash);
      if (group) openMenu(`group:${stash}`, event, groupItems(group));
    },
    onGroupKey: (stash: string, event: KeyboardEvent) => {
      const group = whole(stash);
      if (group) keyMenu(`group:${stash}`, event, () => groupItems(group));
    },
    onRestore: (stash: string, member: StashMember) => {
      const group = whole(stash);
      if (group) void store.restore(group, [member]);
    },
    onMemberMenu: (stash: string, member: StashMember, event: MouseEvent) => {
      const group = whole(stash);
      if (group) openMenu(`${stash}/${member.id}`, event, memberItems(group, member));
    },
    onMemberKey: (stash: string, member: StashMember, event: KeyboardEvent) => {
      const group = whole(stash);
      if (group) keyMenu(`${stash}/${member.id}`, event, () => memberItems(group, member));
    },
  });

  const onFocus = (event: FocusEvent) =>
    setFocusedKey((event.target as HTMLElement).closest<HTMLElement>("[data-key]")?.dataset.key);
  const onBlur = (event: FocusEvent<HTMLElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setFocusedKey(undefined);
  };

  return (
    <div className="stash-page" aria-busy={snap.busy || undefined}>
      <header className="stash-header">
        <div className="stash-title-row">
          <h1 className="stash-title">{t("stash.title")}</h1>
          {!snap.importOpen && (
            <button type="button" className="stash-text-button" disabled={off} onClick={() => store.openImport()}>
              {t("stash.import.button")}
            </button>
          )}
        </div>
        {snap.groups.length > 0 && (
          <input
            className="stash-search"
            type="search"
            placeholder={t("stash.search")}
            aria-label={t("stash.search")}
            value={snap.query}
            onChange={(event) => store.setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape" && snap.query && !event.metaKey && !event.ctrlKey && !event.altKey) {
                store.setQuery("");
                event.preventDefault();
              }
            }}
          />
        )}
        {snap.importOpen && (
          <div className="stash-import">
            <p className="stash-import-hint">{t("stash.import.hint")}</p>
            <textarea
              className="stash-import-text"
              aria-label={t("stash.import.button")}
              value={snap.importText}
              disabled={off}
              // oxlint-disable-next-line jsx-a11y/no-autofocus
              autoFocus
              onChange={(event) => store.setImportText(event.target.value)}
            />
            <div className="stash-import-actions">
              <button type="button" className="stash-text-button" onClick={() => store.closeImport()}>
                {t("stash.import.cancel")}
              </button>
              <button
                type="button"
                className="stash-text-button primary"
                disabled={off || !snap.importText.trim()}
                onClick={() => void store.importPasted()}
              >
                {t("stash.import.action")}
              </button>
            </div>
          </div>
        )}
        {snap.notice && (
          <p className="stash-notice" role={snap.notice.kind === "error" ? "alert" : "status"}>
            {noticeText(snap.notice, strings)}
          </p>
        )}
      </header>
      {/* The rows stay while the link is down; a corner mark says so once it lasts (ui/ConnectionChip.tsx). */}
      {downLasting ? <ConnectionChip text={t("stash.disconnected")} /> : null}
      {shown.length === 0 ? (
        <div className="stash-empty">
          {snap.loading || down ? "" : t(snap.groups.length ? "stash.noMatches" : "stash.empty")}
        </div>
      ) : (
        <div ref={setScroller} className="stash-list" onFocus={onFocus} onBlur={onBlur}>
          <div
            className="stash-list-space"
            // A list of absolutely placed items: its group headers are not list items, so no `ul`.
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="list"
            style={{ height: virtualizer.getTotalSize() }}
          >
            {virtualizer.getVirtualItems().map(({ index, start }) => {
              const item = list.items[index]!;
              return item.kind === "group" ? (
                <GroupHeader
                  key={`group:${item.group.id}`}
                  index={index}
                  top={start}
                  measure={measure}
                  stash={item.group.id}
                  name={item.group.name || t("stash.untitled")}
                  date={date.format(item.group.created_at_ms)}
                  count={count.format(item.whole.members.length)}
                  restoreAll={t("stash.restoreAll")}
                  off={off}
                  onRestoreAll={handlers.onRestoreAll}
                  onMenu={handlers.onGroupMenu}
                  onMenuKey={handlers.onGroupKey}
                />
              ) : (
                <StashRow
                  key={`${item.group.id}/${item.member.id}`}
                  index={index}
                  top={start}
                  measure={measure}
                  stash={item.group.id}
                  member={item.member}
                  time={time.format(item.group.created_at_ms)}
                  position={item.row + 1}
                  setSize={list.rows}
                  untitledWorkspace={t("stash.untitledWorkspace")}
                  language={language}
                  off={off}
                  onRestore={handlers.onRestore}
                  onMenu={handlers.onMemberMenu}
                  onMenuKey={handlers.onMemberKey}
                />
              );
            })}
          </div>
        </div>
      )}
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
  /** The stash the item belongs to. */
  stash: string;
  off: boolean;
}

interface HeaderProps extends Placed {
  name: string;
  date: string;
  count: string;
  restoreAll: string;
  onRestoreAll: (stash: string) => void;
  onMenu: (stash: string, event: MouseEvent) => void;
  onMenuKey: (stash: string, event: KeyboardEvent) => void;
}

const GroupHeader = memo(function GroupHeader({
  index,
  top,
  measure,
  stash,
  off,
  name,
  date,
  count,
  restoreAll,
  onRestoreAll,
  onMenu,
  onMenuKey,
}: HeaderProps) {
  return (
    <section
      ref={measure}
      data-index={index}
      data-size="group"
      data-key={`group:${stash}`}
      // Its rows are its siblings in the windowed list, not its children: they carry the same `data-stash`.
      data-stash={stash}
      className="stash-group"
      aria-label={name}
      style={{ transform: `translateY(${top}px)` }}
    >
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions */}
      <div
        className="stash-group-header"
        onContextMenu={(event) => onMenu(stash, event)}
        onKeyDown={(event) => onMenuKey(stash, event)}
      >
        <h2 className="stash-group-name">{name}</h2>
        <span className="stash-meta">{date}</span>
        <span className="stash-meta stash-count">{count}</span>
        {/* The group's one visible action, on its header row (the native page's first); Restore in
            New Workspace and Delete Group are in the header's menu (a right-click, or Shift-F10 /
            the context-menu key on Restore All). */}
        <button
          type="button"
          className="stash-text-button stash-group-restore"
          disabled={off}
          onClick={() => onRestoreAll(stash)}
        >
          {restoreAll}
        </button>
      </div>
    </section>
  );
});

interface RowProps extends Placed {
  member: StashMember;
  time: string;
  /** 1-based place among every shown member, and their count: the screen reader's "3 of 1000". */
  position: number;
  setSize: number;
  untitledWorkspace: string;
  language: string;
  onRestore: (stash: string, member: StashMember) => void;
  onMenu: (stash: string, member: StashMember, event: MouseEvent) => void;
  onMenuKey: (stash: string, member: StashMember, event: KeyboardEvent) => void;
}

const StashRow = memo(function StashRow({
  index,
  top,
  measure,
  stash,
  off,
  member,
  time,
  position,
  setSize,
  untitledWorkspace,
  language,
  onRestore,
  onMenu,
  onMenuKey,
}: RowProps) {
  const tabs = workspaceTabs(member);
  const workspace = isWorkspace(member);
  const aside = workspace
    ? tabs.length
      ? intl.ListFormat(language, { style: "narrow" }).format(tabs)
      : undefined
    : memberHost(member);
  return (
    // The row's menu (a right-click, or Shift-F10 on its button) is on the item, as it was before
    // the row was a list item.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
    <div
      ref={measure}
      data-index={index}
      data-size="row"
      data-key={`${stash}/${member.id}`}
      data-stash={stash}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={position}
      aria-setsize={setSize}
      className="stash-row"
      style={{ transform: `translateY(${top}px)` }}
      onContextMenu={(event) => onMenu(stash, member, event)}
      onKeyDown={(event) => onMenuKey(stash, member, event)}
    >
      <WithFacts facts={[{ value: (workspace ? tabs.join("\n") : member.url) ?? "" }]}>
        {(facts) => (
          <button
            {...facts}
            type="button"
            className="stash-row-main"
            disabled={off}
            onClick={() => onRestore(stash, member)}
          >
            <span className="stash-row-icon">
              <Glyph path={workspace ? ICONS.workspace : ICONS.page} />
            </span>
            <span className="stash-row-title">{memberTitle(member, untitledWorkspace)}</span>
            {aside && <span className="stash-row-aside">{aside}</span>}
            <span className="stash-row-time">{time}</span>
          </button>
        )}
      </WithFacts>
    </div>
  );
});
