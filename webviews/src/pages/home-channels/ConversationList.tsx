// The left list: my pinned conversations first under a quiet "Pinned" label, in my pin order,
// then every conversation in one chronological list, newest activity first: channels, people and
// Chiefs together. A row is two quiet lines on a fixed grid: a 20 px mark (hash tile, person, or
// Chief with its live state), the name and the time; then a one-line preview (the author in a
// room) or the Chief's state. Unread rows (or rows I marked unread) have a dot in the gutter and a
// bright name; mentions show a count. A right-click on a row, or Shift-F10 / the context-menu key
// on a focused row, opens its menu: Pin or Unpin, Mark as Read or Unread, Copy Link. The list is
// transparent over the window. Under the search field, New Cloud Machine runs the app's own action
// (the Cloud machine sheet), so a remote computer has a visible way in from Home.
// The rows are windowed: only those near the viewport (about one viewport each side) are mounted,
// plus the active row, the row that last held focus and the Pinned label, so 10,000 conversations
// cost what 1,000 do. Rows are memoized on their conversation and a few plain values (the time's
// text, the author's name, the offset) with stable handlers, so a selection, a new message or a
// parent render draws only the rows whose text changed.
// A row away from the window is still reached as when every row was mounted: a new selection (a
// link, the palette, Option-Up/Down, the host's next conversation) scrolls its row into view, and
// the browser's Tab and Shift-Tab go to the next row in list order (each row is a tab stop) and into
// the list at its first or last conversation, as the focused row's neighbours and the first and last
// rows stay mounted.
import { memo, useCallback, useLayoutEffect, useMemo, useRef, useState, type FocusEvent, type ReactNode } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../../agent-session/acpmux/stableHandlers";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { SplitEdge } from "../../ui/SplitEdge";
import type { Strings } from "../shared/i18n";
import { Avatar, ChannelMark } from "./Avatar";
import { HomeIcon } from "./icons";
import { activityAt, chiefState, conversationName, isUnread, listOrder, type ChiefState } from "./model";
import { chiefBackendChip, type HomeChief, type HomeConversation, type HomeParticipant } from "./types";
import { intl } from "../../ui/intl";
import { useLasting } from "../../ui/lasting";
import { KeyHint } from "../../ui/KeyHint";

/** Where the list shows New Cloud Machine: a labeled row under the search field (`row`, the page's),
 * an icon in the header beside New Message and New Chief (`header`), or a labeled row at the foot of
 * the list (`footer`). The gallery shows all three. */
export type CloudEntryLook = "row" | "header" | "footer";

/** What a row's menu does; the page owns the actions. */
export interface ListRowActions {
  /** The owner keeps my pins and marks (else only Mark as Read and Copy Link show). */
  canPin: boolean;
  onPin(id: string, pinned: boolean): void;
  onMarkUnread(id: string): void;
  onMarkRead(id: string): void;
  onCopyLink(id: string): void;
}

export interface ConversationListProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  channels: ReadonlySet<string>;
  people: ReadonlyMap<string, HomeParticipant>;
  activity: ReadonlyMap<string, ReadonlySet<string>>;
  me?: string;
  selected?: string;
  strings: Strings;
  onSelect(id: string): void;
  onOpenPalette(): void;
  /** New message or channel: opens the page's #/new/message sheet (absent: the owner cannot). */
  onCompose?(): void;
  /** New Chief: opens the page's #/new/chief page (absent: the owner has no Chief registry). */
  onNewChief?(): void;
  /** New Cloud Machine: runs the app's `newCloudMachine` action (absent: no app host to run it). */
  onNewCloudMachine?(): void;
  cloudEntry?: CloudEntryLook;
  actions: ListRowActions;
  /** The Chief records by id: a Chief's row names its engine when it is not the default. */
  chiefs?: ReadonlyMap<string, HomeChief>;
  /** Why the last Cloud inbox read failed: the Cloud rows stay (the last good list) and this says
   * so in the list's own note line while the page reads again. */
  cloudError?: string;
}

export function ConversationList({
  conversations,
  channels,
  people,
  activity,
  me,
  selected,
  strings,
  onSelect,
  onOpenPalette,
  onCompose,
  onNewChief,
  onNewCloudMachine,
  cloudEntry = "row",
  actions,
  chiefs,
  cloudError,
}: ConversationListProps) {
  const { t, format } = strings;
  // The store reads the Cloud inbox again on its own (store.ts `retryCloud`); a failure says nothing
  // until it has lasted the house deadline, then one quiet line with no button.
  const cloudLasting = useLasting(!!cloudError);
  const cloudRow = (look: CloudEntryLook) =>
    onNewCloudMachine &&
    cloudEntry === look && (
      <button
        type="button"
        className="lg-nav-row"
        data-look={look}
        data-new-cloud-machine=""
        onClick={onNewCloudMachine}
      >
        <HomeIcon name="cloud" size={14} />
        <span>{t("action.newCloudMachine")}</span>
      </button>
    );
  const list = useMemo(() => listModel(conversations.values()), [conversations]);
  const { pinned, rest } = list;
  const stamp = useStamp(strings.language);
  const scroller = useRef<HTMLDivElement | null>(null);
  // The row that last held focus stays mounted however far the list scrolls: keys arrive at it, and
  // a closed menu gives focus back to it.
  const [focusedRow, setFocusedRow] = useState<string | undefined>(undefined);
  const selectedItem = selected === undefined ? -1 : (list.index.get(selected) ?? -1);
  const focusedItem = focusedRow === undefined ? -1 : (list.index.get(focusedRow) ?? -1);
  const tabStops = [
    focusedItem,
    focusedItem < 0 ? -1 : rowFrom(list.items, focusedItem - 1, -1),
    focusedItem < 0 ? -1 : rowFrom(list.items, focusedItem + 1, 1),
    rowFrom(list.items, 0, 1),
    rowFrom(list.items, list.items.length - 1, -1),
  ];
  // One function per list: TanStack places every item again when it changes.
  const itemKey = useCallback((index: number) => itemKeyOf(list.items[index]), [list]);
  // The first mounted item of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N items again whenever a measure differs.
  const sizes = useRef(new Map<SizeKind, number>());
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so the list stays uncompiled on purpose; this list keeps its own range (the Pinned label, the selected row and the focused row stay mounted), keys items by conversation id and learns each row kind's height from its first measured item, where VirtualList keys by index, keeps one active row and takes one estimate, so ui/VirtualList does not fit.
  const virtualizer = useVirtualizer({
    count: list.items.length,
    getScrollElement: () => scroller.current,
    estimateSize: (index) => {
      const kind = list.items[index]?.kind ?? "row";
      return sizes.current.get(kind) ?? ESTIMATE[kind];
    },
    getItemKey: itemKey,
    overscan: OVERSCAN,
    // The Pinned label (its list names it), the active row and the focused row stay mounted; so do
    // the focused row's neighbours and the first and last rows, the browser's next tab stops: Tab
    // and Shift-Tab go on in list order, and into the list at its first or last conversation.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      for (const kept of [pinned.length > 0 ? 0 : -1, selectedItem, ...tabStops])
        if (kept >= 0 && kept < list.items.length && !indexes.includes(kept)) {
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
  // One function per handler for every render: a memo row draws again only when its own props change.
  const handlers = useStableHandlers({
    onSelect,
    onPin: actions.onPin,
    onMarkUnread: actions.onMarkUnread,
    onMarkRead: actions.onMarkRead,
    onCopyLink: actions.onCopyLink,
  });
  const onFocus = (event: FocusEvent<HTMLDivElement>) => {
    const id = (event.target as HTMLElement).closest<HTMLElement>("[data-list-row]")?.dataset.listRow;
    if (id !== undefined) setFocusedRow(id);
  };
  // A new selection scrolls its row into view (each row was in the page when all were mounted). A
  // selection whose conversation has not come yet (a link opened before the inbox reply) is revealed
  // when it comes.
  const revealed = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    if (selected === revealed.current || (selected !== undefined && selectedItem < 0)) return;
    revealed.current = selected;
    if (selectedItem >= 0) virtualizer.scrollToIndex(selectedItem, { align: "auto" });
  });

  // Only the mounted items: each row's plain values are read here, from its own conversation.
  let section: ReactNode = null;
  let divider: ReactNode = null;
  const pinnedRows: ReactNode[] = [];
  const restRows: ReactNode[] = [];
  for (const { index, start } of virtualizer.getVirtualItems()) {
    const item = list.items[index];
    if (!item) continue;
    if (item.kind === "section") {
      section = (
        <div
          key="section"
          ref={measure}
          data-index={index}
          data-size="section"
          className="lg-list-section-host"
          style={{ transform: `translateY(${start}px)` }}
        >
          <h2 className="lg-list-section" id="lg-list-pinned">
            {t("list.pinned")}
          </h2>
        </div>
      );
      continue;
    }
    if (item.kind === "divider") {
      divider = (
        <div
          key="divider"
          ref={measure}
          data-index={index}
          data-size="divider"
          className="lg-list-divider"
          aria-hidden="true"
          style={{ transform: `translateY(${start}px)` }}
        />
      );
      continue;
    }
    const row = item.row;
    const channel = channels.has(row.id);
    const other = channel ? undefined : row.participants.find((p) => p.id !== me);
    const author = row.lastAuthor === me ? t("preview.you") : people.get(row.lastAuthor ?? "")?.name;
    (item.pinned ? pinnedRows : restRows).push(
      <ListRow
        key={row.id}
        index={index}
        top={start}
        measure={measure}
        position={item.place + 1}
        count={item.pinned ? pinned.length : rest.length}
        row={row}
        channel={channel}
        author={author}
        me={me}
        active={row.id === selected}
        state={channel ? undefined : chiefState(row, me, activity.get(row.id))}
        backend={other?.chief ? chiefBackendChip(t, chiefs?.get(other.id)) : undefined}
        time={stamp(activityAt(row))}
        strings={strings}
        canPin={actions.canPin}
        {...handlers}
      />,
    );
  }
  return (
    <nav className="lg-list" aria-label={t("page.title")}>
      <header className="lg-list-header">
        <span className="lg-list-title">{t("page.title")}</span>
        {onCompose && (
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("action.newMessage")}
            title={t("action.newMessage")}
            onClick={onCompose}
          >
            <HomeIcon name="compose" size={16} />
          </button>
        )}
        {onNewChief && (
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("action.newChief")}
            title={t("action.newChief")}
            data-new-chief=""
            onClick={onNewChief}
          >
            <HomeIcon name="chiefAdd" size={16} />
          </button>
        )}
        {onNewCloudMachine && cloudEntry === "header" && (
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("action.newCloudMachine")}
            title={t("action.newCloudMachine")}
            data-new-cloud-machine=""
            onClick={onNewCloudMachine}
          >
            <HomeIcon name="cloud" size={16} />
          </button>
        )}
      </header>
      <button type="button" className="lg-search" onClick={onOpenPalette}>
        <HomeIcon name="search" size={14} />
        <span>{t("list.search")}</span>
        <KeyHint keys="⌘K" />
      </button>
      {cloudRow("row")}
      {cloudError && cloudLasting && (
        <output className="lg-list-empty lg-cloud-error selectable" data-cloud-error="">
          {format("cloud.unreachable", cloudError)}
        </output>
      )}
      {pinned.length + rest.length === 0 && <p className="lg-list-empty">{t("rail.empty")}</p>}
      <div ref={scroller} className="lg-list-rows" onFocus={onFocus}>
        <div className="lg-list-space" style={{ height: virtualizer.getTotalSize() }}>
          {section}
          {pinned.length > 0 && (
            <ul className="lg-list-group" aria-labelledby="lg-list-pinned">
              {pinnedRows}
            </ul>
          )}
          {divider}
          <ul className="lg-list-group">{restRows}</ul>
        </div>
      </div>
      {cloudRow("footer")}
      {/* Its line is the split's divider and drags as one (ui/SplitEdge.tsx); the page's grid reads the width. */}
      <SplitEdge
        side="end"
        property="--home-channels-list-width"
        storageKey="cmux.homeChannels.list.width"
        min={200}
        max={480}
        on="parent"
      />
    </nav>
  );
}

/** Short times on one grid: "14:02" today, "Mon" this week, "Oct 3" before. */
export function useStamp(language: string): (at: number) => string {
  return useMemo(() => {
    const clock = intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" });
    const weekday = intl.DateTimeFormat(language, { weekday: "short" });
    const date = intl.DateTimeFormat(language, { month: "short", day: "numeric" });
    return (at: number) => {
      if (!at) return "";
      const now = new Date();
      const day = new Date(at);
      const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      if (at >= startOfToday) return clock.format(day);
      if (at >= startOfToday - 6 * 86_400_000) return weekday.format(day);
      return date.format(day);
    };
  }, [language]);
}

/** The kinds of item whose heights differ: the Pinned label, the line after my pins, a row. */
type SizeKind = "section" | "divider" | "row";
/** Heights before the first of each kind is measured (ledger.css). */
const ESTIMATE: Record<SizeKind, number> = { section: 26, divider: 13, row: 44 };
/** About one viewport of 44 px rows (600 px, as the Messages list's) above and below the visible ones. */
const OVERSCAN = 14;

type ListItem =
  | { kind: "section" }
  | { kind: "divider" }
  | { kind: "row"; row: HomeConversation; pinned: boolean; place: number };

const SECTION: ListItem = { kind: "section" };
const DIVIDER: ListItem = { kind: "divider" };

const itemKeyOf = (item: ListItem | undefined) =>
  item === undefined || item.kind !== "row" ? (item?.kind ?? "") : item.row.id;

/** The first row from `index` on in the direction `step` (past the Pinned label and the line), or -1. */
function rowFrom(items: readonly ListItem[], index: number, step: 1 | -1): number {
  for (let at = index; at >= 0 && at < items.length; at += step) if (items[at]!.kind === "row") return at;
  return -1;
}
/** The list as it shows, built once per change of the conversations: the Pinned label and my pins,
 * the line after them, then the rest; and each conversation's place in it. */
function listModel(conversations: Iterable<HomeConversation>) {
  const { pinned, rest } = listOrder(conversations);
  const items: ListItem[] = [];
  const index = new Map<string, number>();
  const add = (rows: readonly HomeConversation[], isPinned: boolean) =>
    rows.forEach((row, place) => {
      index.set(row.id, items.length);
      items.push({ kind: "row", row, pinned: isPinned, place });
    });
  if (pinned.length > 0) {
    items.push(SECTION);
    add(pinned, true);
    items.push(DIVIDER);
  }
  add(rest, false);
  return { pinned, rest, items, index };
}

interface ListRowProps {
  /** Where the row sits: its index (TanStack measures it by `data-index`) and its offset. */
  index: number;
  top: number;
  measure(element: HTMLElement | null): void;
  /** 1-based place in its list, and the list's count: the screen reader's "3 of 1000". */
  position: number;
  count: number;
  row: HomeConversation;
  channel: boolean;
  /** The last message's author as the preview names it ("You" for me). */
  author?: string;
  me?: string;
  active: boolean;
  state?: ChiefState;
  /** A Chief's engine when it is not the default (its chip by the name). */
  backend?: string;
  /** The row's time as it reads now ("14:02", "Mon", "Oct 3"). */
  time: string;
  strings: Strings;
  canPin: boolean;
  onSelect(id: string): void;
  onPin(id: string, pinned: boolean): void;
  onMarkUnread(id: string): void;
  onMarkRead(id: string): void;
  onCopyLink(id: string): void;
}

const ListRow = memo(function ListRow({
  index,
  top,
  measure,
  position,
  count,
  row,
  channel,
  author,
  me,
  active,
  state,
  backend,
  time,
  strings,
  canPin,
  onSelect,
  onPin,
  onMarkUnread,
  onMarkRead,
  onCopyLink,
}: ListRowProps) {
  const { t, format } = strings;
  const name = conversationName(row, me);
  const other = channel ? undefined : row.participants.find((p) => p.id !== me);
  const unread = isUnread(row);
  const badge = row.mentions > 0 ? row.mentions : !channel && unread && row.unread > 1 ? row.unread : 0;
  const preview = row.lastText ?? "";
  const showAuthor = author !== undefined && (channel || row.lastAuthor === me) && preview !== "";
  const label = channel ? `#${name}` : name;
  const read = row.unread > 0 || row.markedUnread === true;
  const items: ContextMenuItem[] = [];
  if (canPin)
    items.push({
      id: "pin",
      label: t(row.pinned ? "menu.unpin" : "menu.pin"),
      onSelect: () => onPin(row.id, !row.pinned),
    });
  if (read) items.push({ id: "read", label: t("menu.markRead"), onSelect: () => onMarkRead(row.id) });
  else if (canPin) items.push({ id: "unread", label: t("menu.markUnread"), onSelect: () => onMarkUnread(row.id) });
  items.push({
    id: "link",
    label: t("action.copyLink"),
    separatorBefore: items.length > 0,
    onSelect: () => onCopyLink(row.id),
  });
  return (
    <li
      ref={measure}
      data-index={index}
      data-size="row"
      aria-posinset={position}
      aria-setsize={count}
      style={{ transform: `translateY(${top}px)` }}
    >
      <ContextMenu items={items} className="lg-row-host">
        <button
          type="button"
          data-list-row={row.id}
          className={`lg-row${active ? " active" : ""}${unread ? " unread" : ""}${row.muted ? " muted" : ""}`}
          aria-current={active ? "page" : undefined}
          data-name={label}
          data-pinned={row.pinned ? "" : undefined}
          onClick={() => onSelect(row.id)}
        >
          {unread && <span className="lg-unread-dot" aria-hidden="true" />}
          <span className="lg-row-mark">
            {channel ? <ChannelMark /> : <Avatar participant={other} size={20} state={state} />}
          </span>
          <span className={`lg-row-name${backend ? " with-backend" : ""}`}>
            {channel && <span className="lg-visually-hidden">#</span>}
            {backend ? <span className="lg-row-name-text">{name}</span> : name}
            {backend && <span className="hc-tag">{backend}</span>}
            {unread && badge === 0 && (
              <span className="lg-visually-hidden">
                , {row.unread > 0 ? format("unread.messages", String(row.unread)) : t("unread.marked")}
              </span>
            )}
          </span>
          <time className="lg-row-time">{time}</time>
          <span className="lg-row-preview">
            {state === "working" || state === "waiting" ? (
              <span className={`lg-state ${state}`}>{t(state === "working" ? "chief.working" : "chief.waiting")}</span>
            ) : null}
            {(state === "working" || state === "waiting") && preview && <span className="lg-sep">·</span>}
            {showAuthor && <span className="lg-row-author">{author}</span>}
            <span className="lg-row-text">{preview}</span>
          </span>
          {badge > 0 && (
            <>
              <span className="lg-count" aria-hidden="true">
                {badge}
              </span>
              <span className="lg-visually-hidden">
                {format(row.mentions > 0 ? "unread.mentions" : "unread.messages", String(badge))}
              </span>
            </>
          )}
        </button>
      </ContextMenu>
    </li>
  );
});
