// The Messages mirror page (cmux-page://cmux.imessage/): this Mac's Messages conversations, read
// only. Threads on the left (title, group mark, last message, its time), the open conversation on
// the right (bubbles: mine on the trailing side in Messages blue, others on the leading side with
// the sender's handle in groups, day lines, attachment chips). Scrolling up reads the page before
// the oldest bubble; a live update keeps the view at the bottom when it was there.
import { useLayoutEffect, useMemo, useRef, useSyncExternalStore, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import {
  attachmentKind,
  attachmentName,
  conversationRows,
  initials,
  offsetZone,
  relativeKind,
  type ConversationRow,
} from "./model";
import type { Conversation, ImessageStore } from "./store";
import type { Attachment, Message, Thread } from "./types";

/** Bubble tones for the gallery's comparison; `messages` (Messages blue) ships. */
export type BubbleTone = "messages" | "accent" | "neutral";

export interface PageClock {
  now: () => number;
  /** The person's UTC offset in minutes, east positive. */
  offsetMinutes: number;
}

export const localClock = (): PageClock => ({ now: () => Date.now(), offsetMinutes: -new Date().getTimezoneOffset() });

const LOCAL_CLOCK = localClock();

/** How close to the top (px) scrolling reads the older page. */
const OLDER_THRESHOLD = 160;
/** How close to the bottom (px) counts as pinned there. */
const PINNED_SLACK = 32;

export function ImessagePage({
  store,
  strings,
  clock = LOCAL_CLOCK,
  tone = "messages",
}: {
  store: ImessageStore;
  strings: Strings;
  clock?: PageClock;
  tone?: BubbleTone;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const time = useMemo(() => timeFormats(strings, clock), [strings, clock]);
  const { phase } = snapshot;

  let body: ReactNode;
  if (phase === "ready" && snapshot.threads.length > 0) {
    const thread = snapshot.threads.find((item) => item.chat_id === snapshot.selected);
    body = (
      <>
        <ThreadList
          threads={snapshot.threads}
          selected={snapshot.selected}
          strings={strings}
          time={time}
          onSelect={(chatId) => void store.select(chatId)}
        />
        {thread ? (
          <ConversationView
            key={thread.chat_id}
            thread={thread}
            conversation={snapshot.conversation}
            strings={strings}
            time={time}
            onOlder={() => void store.loadOlder()}
            onRetry={() => void store.refresh()}
          />
        ) : (
          <section className="im-conversation im-conversation-empty">
            <p className="im-muted">{strings.t("imessage.select")}</p>
          </section>
        )}
      </>
    );
  } else {
    body = <StateCard store={store} phase={phase} strings={strings} />;
  }

  return (
    <div className={`im-page${phase === "ready" && snapshot.threads.length > 0 ? "" : " is-state"}`} data-tone={tone}>
      {!snapshot.connected && phase !== "unavailable" && (
        <p className="im-banner" role="status">
          {strings.t("imessage.disconnected")}
        </p>
      )}
      {body}
    </div>
  );
}

function StateCard({ store, phase, strings }: { store: ImessageStore; phase: string; strings: Strings }) {
  const t = strings.t;
  const card = (
    kind: string,
    title: string,
    lines: string[],
    action?: { label: string; run: () => void },
    note?: string,
  ) => (
    <section className="im-state" data-state={kind} aria-live="polite">
      <MessagesGlyph />
      <h1 className="im-state-title">{title}</h1>
      {lines.map((line) => (
        <p key={line} className="im-state-body">
          {line}
        </p>
      ))}
      {action && (
        <button type="button" className="im-button" onClick={action.run}>
          {action.label}
        </button>
      )}
      {note && <p className="im-state-note">{note}</p>}
    </section>
  );
  switch (phase) {
    case "loading":
      return (
        <section className="im-state" data-state="loading" aria-busy="true">
          <p className="im-muted">{t("imessage.loading")}</p>
        </section>
      );
    case "unavailable":
      return card("unavailable", t("imessage.page.title"), [t("imessage.unavailable")]);
    case "off":
      return card(
        "off",
        t("imessage.off.title"),
        [t("imessage.off.body")],
        { label: t("imessage.off.action"), run: () => void store.openSettings() },
        t("imessage.off.privacy"),
      );
    case "not_permitted":
      return card(
        "not_permitted",
        t("imessage.access.title"),
        [t("imessage.access.body")],
        { label: t("imessage.access.action"), run: () => void store.openFullDiskAccess() },
        t("imessage.access.note"),
      );
    case "missing":
      return card("missing", t("imessage.missing.title"), [t("imessage.missing.body")], {
        label: t("imessage.retry"),
        run: () => void store.refresh(),
      });
    case "ready":
      return card("empty", t("imessage.empty.title"), [t("imessage.empty.body")], undefined, t("imessage.off.privacy"));
    default:
      return card("error", t("imessage.error.title"), [t("imessage.error.body")], {
        label: t("imessage.retry"),
        run: () => void store.refresh(),
      });
  }
}

interface TimeFormats {
  offsetMinutes: number;
  listTime(at: number): string;
  dayLine(at: number): string;
}

function timeFormats(strings: Strings, clock: PageClock): TimeFormats {
  const language = strings.language;
  const timeZone = offsetZone(clock.offsetMinutes);
  const zone = timeZone ? { timeZone } : {};
  const hour = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit", ...zone });
  const weekday = new Intl.DateTimeFormat(language, { weekday: "long", ...zone });
  const short = new Intl.DateTimeFormat(language, { year: "2-digit", month: "numeric", day: "numeric", ...zone });
  const long = new Intl.DateTimeFormat(language, { weekday: "short", month: "short", day: "numeric", ...zone });
  return {
    offsetMinutes: clock.offsetMinutes,
    listTime(at) {
      const kind = relativeKind(at, clock.now(), clock.offsetMinutes);
      if (kind.kind === "time") return hour.format(at);
      if (kind.kind === "yesterday") return strings.t("imessage.day.yesterday");
      if (kind.kind === "weekday") return weekday.format(at);
      return short.format(at);
    },
    dayLine(at) {
      const kind = relativeKind(at, clock.now(), clock.offsetMinutes);
      const day =
        kind.kind === "time"
          ? strings.t("imessage.day.today")
          : kind.kind === "yesterday"
            ? strings.t("imessage.day.yesterday")
            : kind.kind === "weekday"
              ? weekday.format(at)
              : long.format(at);
      return strings.format("imessage.day.withTime", day, hour.format(at));
    },
  };
}

function ThreadList({
  threads,
  selected,
  strings,
  time,
  onSelect,
}: {
  threads: Thread[];
  selected?: number;
  strings: Strings;
  time: TimeFormats;
  onSelect: (chatId: number) => void;
}) {
  return (
    <nav className="im-list" aria-label={strings.t("imessage.list.label")}>
      <header className="im-list-header">
        <h1 className="im-list-title">{strings.t("imessage.page.title")}</h1>
        <span className="im-readonly">{strings.t("imessage.readOnly")}</span>
      </header>
      <ul className="im-threads">
        {threads.map((thread) => {
          const last = thread.last_message;
          const preview =
            last?.text ?? (last?.has_attachments ? strings.t("imessage.preview.attachment") : strings.t("imessage.preview.empty"));
          const current = thread.chat_id === selected;
          return (
            <li key={thread.chat_id}>
              <button
                type="button"
                className={`im-thread${current ? " is-selected" : ""}`}
                aria-current={current ? "true" : undefined}
                onClick={() => onSelect(thread.chat_id)}
              >
                <ThreadAvatar thread={thread} />
                <span className="im-thread-main">
                  <span className="im-thread-top">
                    <span className="im-thread-title">
                      {thread.is_group && (
                        <span className="im-group-mark" role="img" aria-label={strings.t("imessage.group")}>
                          <PeopleGlyph />
                        </span>
                      )}
                      <span className="im-thread-name">{thread.title}</span>
                    </span>
                    {last?.date_ms != null && <time className="im-thread-time">{time.listTime(last.date_ms)}</time>}
                  </span>
                  <span className="im-thread-preview">{preview}</span>
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

function ThreadAvatar({ thread }: { thread: Thread }) {
  const letters = thread.is_group ? "" : initials(thread.title);
  return (
    <span className="im-avatar" aria-hidden="true">
      {thread.is_group ? <PeopleGlyph /> : letters || <PersonGlyph />}
    </span>
  );
}

function ConversationView({
  thread,
  conversation,
  strings,
  time,
  onOlder,
  onRetry,
}: {
  thread: Thread;
  conversation?: Conversation;
  strings: Strings;
  time: TimeFormats;
  onOlder: () => void;
  onRetry: () => void;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);
  const layout = useRef<{ first?: number; height: number }>({ height: 0 });
  const messages = conversation?.messages ?? [];
  const rows = useMemo(
    () => conversationRows(messages, thread.is_group, time.offsetMinutes),
    [messages, thread.is_group, time],
  );

  // After each render: an older page prepended keeps the bubble under the eye where it was; new
  // messages keep the view at the bottom when it was pinned there.
  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const first = messages[0]?.rowid;
    const before = layout.current;
    if (before.first !== undefined && first !== undefined && first < before.first) {
      element.scrollTop += element.scrollHeight - before.height;
    } else if (pinned.current) {
      element.scrollTop = element.scrollHeight;
    }
    layout.current = { first, height: element.scrollHeight };
  }, [messages]);

  const onScroll = () => {
    const element = scroller.current;
    if (!element) return;
    pinned.current = element.scrollHeight - element.scrollTop - element.clientHeight <= PINNED_SLACK;
    if (element.scrollTop <= OLDER_THRESHOLD && conversation?.hasOlder) onOlder();
  };

  const subtitle = thread.is_group ? thread.participants.join(", ") : (thread.service ?? "");
  return (
    <section className="im-conversation" aria-label={thread.title}>
      <header className="im-conversation-header">
        <ThreadAvatar thread={thread} />
        <span className="im-conversation-heading">
          <span className="im-conversation-title">{thread.title}</span>
          {subtitle && <span className="im-conversation-subtitle">{subtitle}</span>}
        </span>
      </header>
      <div className="im-scroller" ref={scroller} onScroll={onScroll} data-testid="im-scroller">
        {conversation?.loadingOlder && <p className="im-older">{strings.t("imessage.conversation.older")}</p>}
        {conversation?.loading ? (
          <p className="im-conversation-note im-muted">{strings.t("imessage.conversation.loading")}</p>
        ) : conversation?.failed ? (
          <div className="im-conversation-note">
            <p className="im-muted">{strings.t("imessage.conversation.failed")}</p>
            <button type="button" className="im-button" onClick={onRetry}>
              {strings.t("imessage.retry")}
            </button>
          </div>
        ) : rows.length === 0 ? (
          <p className="im-conversation-note im-muted">{strings.t("imessage.conversation.empty")}</p>
        ) : (
          <ol className="im-rows">
            {rows.map((row) => (
              <Row key={row.key} row={row} strings={strings} time={time} />
            ))}
          </ol>
        )}
      </div>
    </section>
  );
}

function Row({ row, strings, time }: { row: ConversationRow; strings: Strings; time: TimeFormats }) {
  if (row.kind === "day") {
    return (
      <li className="im-day">
        <time>{time.dayLine(row.at)}</time>
      </li>
    );
  }
  const { message } = row;
  const side = message.is_from_me ? "mine" : "theirs";
  return (
    <li className={`im-message ${side}${row.first ? " first" : ""}${row.last ? " last" : ""}`} data-rowid={message.rowid}>
      {row.sender && <span className="im-sender">{row.sender}</span>}
      <Bubble message={message} strings={strings} />
    </li>
  );
}

function Bubble({ message, strings }: { message: Message; strings: Strings }) {
  const text = message.text ?? undefined;
  const attachments = message.attachments;
  if (!text && attachments.length === 0) {
    return <p className="im-bubble is-unsupported">{strings.t("imessage.message.unsupported")}</p>;
  }
  return (
    <>
      {attachments.length > 0 && (
        <span className="im-attachments">
          {attachments.map((attachment, index) => (
            <AttachmentChip key={index} attachment={attachment} strings={strings} />
          ))}
        </span>
      )}
      {text && <p className="im-bubble">{text}</p>}
    </>
  );
}

function AttachmentChip({ attachment, strings }: { attachment: Attachment; strings: Strings }) {
  const kind = attachmentKind(attachment);
  const name = attachmentName(attachment) ?? strings.t(`imessage.attachment.${kind}`);
  return (
    <span className="im-attachment" data-kind={kind}>
      <AttachmentGlyph kind={kind} />
      <span className="im-attachment-name">{name}</span>
      {attachment.mime_type && <span className="im-attachment-type">{attachment.mime_type}</span>}
    </span>
  );
}

function MessagesGlyph() {
  return (
    <svg className="im-state-glyph" viewBox="0 0 24 24" aria-hidden="true">
      <path
        d="M12 3.5c-4.97 0-9 3.36-9 7.5 0 2.3 1.25 4.36 3.2 5.73-.12 1.1-.6 2.3-1.5 3.27 1.9-.1 3.4-.83 4.43-1.6.92.2 1.88.3 2.87.3 4.97 0 9-3.36 9-7.5s-4.03-7.7-9-7.7Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function PeopleGlyph() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="6" cy="5.5" r="2.25" fill="currentColor" />
      <circle cx="11" cy="6.25" r="1.75" fill="currentColor" opacity="0.7" />
      <path d="M1.75 13c.3-2.3 2.1-3.75 4.25-3.75S9.95 10.7 10.25 13Z" fill="currentColor" />
      <path d="M10.6 9.6c1.9.1 3.35 1.35 3.65 3.4h-3.1c-.1-1.3-.3-2.4-.55-3.4Z" fill="currentColor" opacity="0.7" />
    </svg>
  );
}

function PersonGlyph() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="8" cy="5.5" r="2.75" fill="currentColor" />
      <path d="M2.75 14c.35-2.85 2.55-4.5 5.25-4.5s4.9 1.65 5.25 4.5Z" fill="currentColor" />
    </svg>
  );
}

function AttachmentGlyph({ kind }: { kind: string }) {
  const paths: Record<string, string> = {
    image: "M2.5 3.5h11v9h-11Z M4.5 10.5l2.5-3 2 2.25 1.5-1.5 2 2.25",
    video: "M2.5 4h8v8h-8Z M10.5 7l3-2v6l-3-2",
    audio: "M4 6v4 M6.5 4v8 M9 5.5v5 M11.5 7v2",
    file: "M4 2.5h5l3 3v8H4Z M9 2.5v3h3",
  };
  return (
    <svg className="im-attachment-glyph" viewBox="0 0 16 16" aria-hidden="true">
      <path d={paths[kind] ?? paths.file} fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" />
    </svg>
  );
}
