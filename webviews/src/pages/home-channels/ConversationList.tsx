// The left list: my pinned conversations first under a quiet "Pinned" label, in my pin order,
// then every conversation in one chronological list, newest activity first: channels, people and
// Chiefs together. A row is two quiet lines on a fixed grid: a 20 px mark (hash tile, person, or
// Chief with its live state), the name and the time; then a one-line preview (the author in a
// room) or the Chief's state. Unread rows (or rows I marked unread) have a dot in the gutter and a
// bright name; mentions show a count. A right-click on a row, or Shift-F10 / the context-menu key
// on a focused row, opens its menu: Pin or Unpin, Mark as Read or Unread, Copy Link. The list is
// transparent over the window.
import { useMemo } from "react";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import type { Strings } from "../shared/i18n";
import { Avatar, ChannelMark } from "./Avatar";
import { HomeIcon } from "./icons";
import { activityAt, chiefState, conversationName, isUnread, listOrder, type ChiefState } from "./model";
import { chiefBackendChip, type HomeChief, type HomeConversation, type HomeParticipant } from "./types";

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
  actions: ListRowActions;
  /** The Chief records by id: a Chief's row names its engine when it is not the default. */
  chiefs?: ReadonlyMap<string, HomeChief>;
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
  actions,
  chiefs,
}: ConversationListProps) {
  const { t } = strings;
  const { pinned, rest } = useMemo(() => listOrder(conversations.values()), [conversations]);
  const stamp = useStamp(strings.language);
  const renderRow = (row: HomeConversation) => {
    const channel = channels.has(row.id);
    const other = channel ? undefined : row.participants.find((p) => p.id !== me);
    const backend = other?.chief ? chiefBackendChip(t, chiefs?.get(other.id)) : undefined;
    return (
      <li key={row.id}>
        <ListRow
          row={row}
          channel={channel}
          people={people}
          me={me}
          active={row.id === selected}
          state={channel ? undefined : chiefState(row, me, activity.get(row.id))}
          backend={backend}
          stamp={stamp}
          strings={strings}
          onSelect={onSelect}
          actions={actions}
        />
      </li>
    );
  };
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
      </header>
      <button type="button" className="lg-search" onClick={onOpenPalette}>
        <HomeIcon name="search" size={14} />
        <span>{t("list.search")}</span>
        <kbd>⌘K</kbd>
      </button>
      {pinned.length + rest.length === 0 && <p className="lg-list-empty">{t("rail.empty")}</p>}
      <div className="lg-list-rows" data-page-scroll="conversations">
        {pinned.length > 0 && (
          <>
            <h2 className="lg-list-section" id="lg-list-pinned">
              {t("list.pinned")}
            </h2>
            <ul className="lg-list-group" aria-labelledby="lg-list-pinned">
              {pinned.map(renderRow)}
            </ul>
          </>
        )}
        <ul className={`lg-list-group${pinned.length > 0 ? " after-pinned" : ""}`}>{rest.map(renderRow)}</ul>
      </div>
    </nav>
  );
}

/** Short times on one grid: "14:02" today, "Mon" this week, "Oct 3" before. */
export function useStamp(language: string): (at: number) => string {
  return useMemo(() => {
    const clock = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" });
    const weekday = new Intl.DateTimeFormat(language, { weekday: "short" });
    const date = new Intl.DateTimeFormat(language, { month: "short", day: "numeric" });
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

function ListRow({
  row,
  channel,
  people,
  me,
  active,
  state,
  backend,
  stamp,
  strings,
  onSelect,
  actions,
}: {
  row: HomeConversation;
  channel: boolean;
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  active: boolean;
  state?: ChiefState;
  /** A Chief's engine when it is not the default (its chip by the name). */
  backend?: string;
  stamp(at: number): string;
  strings: Strings;
  onSelect(id: string): void;
  actions: ListRowActions;
}) {
  const { t, format } = strings;
  const name = conversationName(row, me);
  const other = channel ? undefined : row.participants.find((p) => p.id !== me);
  const unread = isUnread(row);
  const badge = row.mentions > 0 ? row.mentions : !channel && unread && row.unread > 1 ? row.unread : 0;
  const author = row.lastAuthor === me ? t("preview.you") : people.get(row.lastAuthor ?? "")?.name;
  const preview = row.lastText ?? "";
  const showAuthor = author !== undefined && (channel || row.lastAuthor === me) && preview !== "";
  const label = channel ? `#${name}` : name;
  const read = row.unread > 0 || row.markedUnread === true;
  const items: ContextMenuItem[] = [];
  if (actions.canPin)
    items.push({
      id: "pin",
      label: t(row.pinned ? "menu.unpin" : "menu.pin"),
      onSelect: () => actions.onPin(row.id, !row.pinned),
    });
  if (read) items.push({ id: "read", label: t("menu.markRead"), onSelect: () => actions.onMarkRead(row.id) });
  else if (actions.canPin)
    items.push({ id: "unread", label: t("menu.markUnread"), onSelect: () => actions.onMarkUnread(row.id) });
  items.push({
    id: "link",
    label: t("action.copyLink"),
    separatorBefore: items.length > 0,
    onSelect: () => actions.onCopyLink(row.id),
  });
  return (
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
        <time className="lg-row-time">{stamp(activityAt(row))}</time>
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
  );
}
