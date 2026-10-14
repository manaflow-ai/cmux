// The conversation list: one list, newest activity first, of every conversation (channels, people
// and Chiefs together), as a personal messenger shows it. Each row: a large avatar, the name and the
// time on the first line, then up to two lines of the last message. Unread is weight (the name and
// the preview in full ink), not a count. A Chief row shows what the Chief does now: a slow ring
// while it works, a dot while it waits for me, and the same words in the preview. The list paints
// no fill: the window shows through it.
import { useMemo, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { ConversationAvatar } from "./ConversationAvatar";
import { HomeIcon } from "./icons";
import { channelIds, conversationName, inboxOrder } from "./model";
import { chiefPresence, type Activity } from "./presence";
import type { HomeConversation, HomeParticipant } from "./types";

export interface InboxProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  selected?: string;
  activity: Activity;
  strings: Strings;
  onSelect(id: string): void;
  onOpenPalette(): void;
  /** "New channel": opens the page's create popover at this button. */
  onAddChannel?(anchor: Element): void;
  footer?: ReactNode;
}

export function Inbox({
  conversations,
  people,
  me,
  selected,
  activity,
  strings,
  onSelect,
  onOpenPalette,
  onAddChannel,
  footer,
}: InboxProps) {
  const { t } = strings;
  const rows = useMemo(() => inboxOrder(conversations.values()), [conversations]);
  const channels = useMemo(() => channelIds(conversations.values(), me), [conversations, me]);
  const stamp = useStamp(strings.language);
  return (
    <nav className="hc-inbox" aria-label={t("page.title")}>
      <header className="hc-inbox-head">
        <h1 className="hc-inbox-title">{t("page.title")}</h1>
        {onAddChannel && (
          <button
            type="button"
            className="hc-icon-button hc-inbox-new"
            aria-label={t("rail.addChannel")}
            title={t("rail.addChannel")}
            onClick={(event) => onAddChannel(event.currentTarget)}
          >
            <HomeIcon name="compose" size={18} />
          </button>
        )}
      </header>
      <button type="button" className="hc-search" onClick={onOpenPalette}>
        <HomeIcon name="search" size={15} />
        <span>{t("rail.jump")}</span>
        <kbd>⌘K</kbd>
      </button>
      <ul className="hc-inbox-list">
        {rows.map((row) => (
          <li key={row.id}>
            <InboxRow
              row={row}
              channel={channels.has(row.id)}
              where={(id) => {
                const place = conversations.get(id);
                return place ? (channels.has(id) ? `#${conversationName(place, me)}` : conversationName(place, me)) : undefined;
              }}
              people={people}
              me={me}
              active={row.id === selected}
              activity={activity}
              strings={strings}
              stamp={stamp}
              onSelect={onSelect}
            />
          </li>
        ))}
      </ul>
      {footer}
    </nav>
  );
}

function InboxRow({
  row,
  channel,
  where,
  people,
  me,
  active,
  activity,
  strings,
  stamp,
  onSelect,
}: {
  row: HomeConversation;
  channel: boolean;
  /** The label of another conversation (where a Chief works). */
  where(id: string): string | undefined;
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  active: boolean;
  activity: Activity;
  strings: Strings;
  stamp(at: number): string;
  onSelect(id: string): void;
}) {
  const { t, format } = strings;
  const name = conversationName(row, me);
  const unread = row.unread > 0 && !row.muted;
  const presence = chiefPresence(row, me, activity);
  const author = row.lastAuthor ? people.get(row.lastAuthor) : undefined;
  const text = row.lastText ?? "";
  // Who said it, where that is not obvious: me anywhere, the author in a channel.
  const said =
    row.lastAuthor === me && text
      ? format("preview.you", text)
      : channel && author && text
        ? format("preview.author", author.kind === "agent" ? author.name : author.name.split(" ")[0]!, text)
        : text;
  let state: string | undefined;
  if (presence?.state === "working") {
    const place = presence.where ? where(presence.where) : undefined;
    state = place ? format("chief.workingIn", place) : t("chief.working");
  } else if (presence?.state === "waiting") state = t("chief.waiting");
  return (
    <button
      type="button"
      className={`hc-row${active ? " active" : ""}${unread ? " unread" : ""}${presence ? ` chief ${presence.state}` : ""}`}
      aria-current={active ? "page" : undefined}
      onClick={() => onSelect(row.id)}
    >
      <ConversationAvatar conversation={row} channel={channel} me={me} size={40} presence={presence?.state} />
      <span className="hc-row-text">
        <span className="hc-row-top">
          <span className="hc-row-name">{channel ? `# ${name}` : name}</span>
          {row.lastText !== undefined && <time className="hc-row-time">{stamp(row.lastAt ?? row.updatedAt)}</time>}
        </span>
        <span className="hc-row-preview">
          {state && <span className={`hc-row-state ${presence?.state}`}>{state}</span>}
          {state && said ? " · " : ""}
          {said}
        </span>
      </span>
      {unread && <span className="hc-visually-hidden">{format("unread.messages", String(row.unread))}</span>}
    </button>
  );
}

/** Today: the time; this week: the weekday; else the date. */
function useStamp(language: string): (at: number) => string {
  return useMemo(() => {
    const time = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" });
    const weekday = new Intl.DateTimeFormat(language, { weekday: "short" });
    const date = new Intl.DateTimeFormat(language, { month: "short", day: "numeric" });
    return (at: number) => {
      const now = new Date();
      const day = new Date(at);
      const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      if (at >= midnight) return time.format(day);
      if (at >= midnight - 6 * 86_400_000) return weekday.format(day);
      return date.format(day);
    };
  }, [language]);
}
