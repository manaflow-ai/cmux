// The left list: every conversation in one chronological list, newest activity first: channels,
// people and Chiefs together. A row is two quiet lines on a fixed grid: a 20 px mark (hash tile,
// person, or Chief with its live state), the name and the time; then a one-line preview (the
// author in a room) or the Chief's state. Unread rows have a dot in the gutter and a bright name;
// mentions show a count. The list is transparent over the window.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar, ChannelMark } from "./Avatar";
import { HomeIcon } from "./icons";
import { activityAt, chiefState, chronological, conversationName, type ChiefState } from "./model";
import type { HomeConversation, HomeParticipant } from "./types";

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
  /** New channel: opens the page's create popover at this control. */
  onAddChannel?(anchor: Element): void;
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
  onAddChannel,
}: ConversationListProps) {
  const { t } = strings;
  const rows = useMemo(() => chronological(conversations.values()), [conversations]);
  const stamp = useStamp(strings.language);
  return (
    <nav className="lg-list" aria-label={t("page.title")}>
      <header className="lg-list-header">
        <span className="lg-list-title">{t("page.title")}</span>
        {onAddChannel && (
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("rail.addChannel")}
            title={t("rail.addChannel")}
            onClick={(event) => onAddChannel(event.currentTarget)}
          >
            <HomeIcon name="plus" size={16} />
          </button>
        )}
      </header>
      <button type="button" className="lg-search" onClick={onOpenPalette}>
        <HomeIcon name="search" size={14} />
        <span>{t("list.search")}</span>
        <kbd>⌘K</kbd>
      </button>
      {rows.length === 0 && <p className="lg-list-empty">{t("rail.empty")}</p>}
      <ul className="lg-list-rows">
        {rows.map((row) => {
          const channel = channels.has(row.id);
          return (
            <li key={row.id}>
              <ListRow
                row={row}
                channel={channel}
                people={people}
                me={me}
                active={row.id === selected}
                state={channel ? undefined : chiefState(row, me, activity.get(row.id))}
                stamp={stamp}
                strings={strings}
                onSelect={onSelect}
              />
            </li>
          );
        })}
      </ul>
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
  stamp,
  strings,
  onSelect,
}: {
  row: HomeConversation;
  channel: boolean;
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  active: boolean;
  state?: ChiefState;
  stamp(at: number): string;
  strings: Strings;
  onSelect(id: string): void;
}) {
  const { t, format } = strings;
  const name = conversationName(row, me);
  const other = channel ? undefined : row.participants.find((p) => p.id !== me);
  const unread = row.unread > 0 && !row.muted;
  const badge = row.mentions > 0 ? row.mentions : !channel && unread && row.unread > 1 ? row.unread : 0;
  const author = row.lastAuthor === me ? t("preview.you") : people.get(row.lastAuthor ?? "")?.name;
  const preview = row.lastText ?? "";
  const showAuthor = author !== undefined && (channel || row.lastAuthor === me) && preview !== "";
  const label = channel ? `#${name}` : name;
  return (
    <button
      type="button"
      data-list-row={row.id}
      className={`lg-row${active ? " active" : ""}${unread ? " unread" : ""}${row.muted ? " muted" : ""}`}
      aria-current={active ? "page" : undefined}
      aria-label={label}
      onClick={() => onSelect(row.id)}
    >
      {unread && <span className="lg-unread-dot" aria-label={format("unread.messages", String(row.unread))} />}
      <span className="lg-row-mark">{channel ? <ChannelMark /> : <Avatar participant={other} size={20} state={state} />}</span>
      <span className="lg-row-name">{name}</span>
      <time className="lg-row-time">{stamp(activityAt(row))}</time>
      <span className="lg-row-preview">
        {state === "working" || state === "waiting" ? (
          <span className={`lg-state ${state}`}>{t(state === "working" ? "chief.working" : "chief.waiting")}</span>
        ) : null}
        {(state === "working" || state === "waiting") && preview && <span className="lg-sep">·</span>}
        {showAuthor && <span className="lg-row-author">{author}</span>}
        <span className="lg-row-text">{preview}</span>
      </span>
      {badge > 0 && <span className="lg-count">{badge}</span>}
    </button>
  );
}
