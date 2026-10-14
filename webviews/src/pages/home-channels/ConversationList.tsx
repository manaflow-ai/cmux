// The left list: every conversation in one list, newest activity first, people, Chiefs and
// channels mixed (Messages-view rows): a kind tile (a face for a person, a rounded tile for an
// agent or Chief, a # tile for a channel), the name and the time, the last message, and one quiet
// line of state: a Chief's live state, or a channel's open threads. Unread rows are bold with a
// dot. The list paints no fill: the window shows through, as in the native sidebar.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { chiefState, type ChiefState } from "./chiefState";
import { HomeIcon } from "./icons";
import { channelIds, conversationName } from "./model";
import type { ThreadEdits, ThreadIndexEntry } from "./threads";
import type { HomeConversation, HomeParticipant } from "./types";
import { useClock, shortTime } from "./time";

export interface ConversationListProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
  selected?: string;
  busy: ReadonlyMap<string, string>;
  threadIndex: ReadonlyMap<string, readonly ThreadIndexEntry[]>;
  threadEdits: ThreadEdits;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
  onSelect(id: string): void;
  onOpenPalette(): void;
  onAddChannel?(anchor: Element): void;
}

export function ConversationList({
  conversations,
  me,
  selected,
  busy,
  threadIndex,
  threadEdits,
  people,
  strings,
  onSelect,
  onOpenPalette,
  onAddChannel,
}: ConversationListProps) {
  const { t } = strings;
  const now = useClock();
  const rows = useMemo(
    () => [...conversations.values()].sort((a, b) => b.updatedAt - a.updatedAt),
    [conversations],
  );
  const channels = useMemo(() => channelIds(conversations.values(), me), [conversations, me]);
  return (
    <nav className="hc-list" aria-label={t("page.title")}>
      <header className="hc-list-header">
        <span className="hc-list-title">{t("page.title")}</span>
        {onAddChannel && (
          <button
            type="button"
            className="hc-icon-button"
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
        <span>{t("list.search")}</span>
        <kbd>⌘K</kbd>
      </button>
      <ul className="hc-list-scroll">
        {rows.map((row) => (
          <li key={row.id}>
            <Row
              row={row}
              me={me}
              now={now}
              channel={channels.has(row.id)}
              active={row.id === selected}
              state={chiefState(row, me, busy)}
              openThreads={openCount(threadIndex.get(row.id), threadEdits)}
              people={people}
              conversations={conversations}
              strings={strings}
              onSelect={onSelect}
            />
          </li>
        ))}
      </ul>
      {conversations.size === 0 && <p className="hc-list-empty">{t("rail.empty")}</p>}
    </nav>
  );
}

function openCount(entries: readonly ThreadIndexEntry[] | undefined, edits: ThreadEdits): number | undefined {
  if (!entries) return undefined;
  return entries.filter((entry) => edits.get(entry.root)?.status !== "resolved").length;
}

function Row({
  row,
  me,
  now,
  channel,
  active,
  state,
  openThreads,
  people,
  conversations,
  strings,
  onSelect,
}: {
  row: HomeConversation;
  me?: string;
  now: number;
  channel: boolean;
  active: boolean;
  state?: ChiefState;
  openThreads?: number;
  people: ReadonlyMap<string, HomeParticipant>;
  conversations: ReadonlyMap<string, HomeConversation>;
  strings: Strings;
  onSelect(id: string): void;
}) {
  const { t, format } = strings;
  const name = conversationName(row, me);
  const other = channel ? undefined : row.participants.find((p) => p.id !== me);
  const unread = row.unread > 0 && !row.muted;
  const author = row.lastAuthor ? people.get(row.lastAuthor) : undefined;
  // In a channel the preview names its author; in a direct conversation only my own lines do.
  const by = row.lastAuthor === me ? t("list.you") : channel ? author?.name.split(" ")[0] : undefined;
  const preview = row.lastText ? (by ? `${by}: ${row.lastText}` : row.lastText) : "";
  const meta = metaLine(state, openThreads, channel, conversations, me, strings);
  return (
    <button
      type="button"
      className={`hc-list-row${active ? " active" : ""}${unread ? " unread" : ""}`}
      aria-current={active ? "page" : undefined}
      onClick={() => onSelect(row.id)}
    >
      <span className="hc-list-tile">
        {channel ? (
          <span className="hc-channel-tile" aria-hidden="true">
            #
          </span>
        ) : (
          <Avatar participant={other} size={38} />
        )}
        {state && state.kind !== "idle" && <span className={`hc-state-dot ${state.kind}`} aria-hidden="true" />}
      </span>
      <span className="hc-list-body">
        <span className="hc-list-line">
          <span className="hc-list-name">{name}</span>
          <time className="hc-list-time">{shortTime(row.updatedAt, now, strings)}</time>
        </span>
        <span className="hc-list-line">
          <span className="hc-list-preview">{preview}</span>
          {unread && (
            <span
              className="hc-unread-dot"
              aria-label={format(row.mentions > 0 ? "unread.mentions" : "unread.messages", String(row.unread))}
            />
          )}
        </span>
        {meta && <span className={`hc-list-meta${state ? ` ${state.kind}` : ""}`}>{meta}</span>}
      </span>
    </button>
  );
}

function metaLine(
  state: ChiefState | undefined,
  openThreads: number | undefined,
  channel: boolean,
  conversations: ReadonlyMap<string, HomeConversation>,
  me: string | undefined,
  strings: Strings,
): string | undefined {
  const { t, format } = strings;
  if (state?.kind === "working") {
    const where = conversations.get(state.conversation);
    return where && where.kind === "group"
      ? format("chief.workingIn", `#${conversationName(where, me)}`)
      : t("chief.working");
  }
  if (state?.kind === "waiting") return t("chief.waiting");
  if (state?.kind === "idle") return t("chief.idle");
  if (channel && openThreads !== undefined)
    return openThreads === 0
      ? t("threads.noneOpen")
      : openThreads === 1
        ? t("threads.openOne")
        : format("threads.openMany", String(openThreads));
  return undefined;
}
