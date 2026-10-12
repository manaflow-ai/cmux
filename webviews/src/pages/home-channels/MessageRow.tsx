// One timeline row: on the first message of a run an author head (avatar, name, Chief tag, time),
// then the body (the agent pane's Markdown renderer), work and attachment chips, reactions and the
// thread summary (reply authors, count, last reply). The hover card (MessageActions) holds the
// row's actions; a delete asks once, inline. A running agent reply is a DraftRow: the same shape,
// with the text growing and a quiet "writing" mark instead of the time.
import { memo, useState, type ReactNode } from "react";
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { Composer } from "./Composer";
import type { HomeDraft } from "./drafts";
import { HomeIcon } from "./icons";
import { MessageActions } from "./MessageActions";
import { messageText, mentionsMe, type ThreadSummary } from "./model";
import type { HomeMessage, HomeParticipant, HomePart } from "./types";

export interface MessageRowProps {
  message: HomeMessage;
  head: boolean;
  thread?: ThreadSummary;
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  strings: Strings;
  timeFormat: Intl.DateTimeFormat;
  /** This row shows the inline editor (the page owns which row edits, so Up can start it). */
  editing: boolean;
  onOpenThread?(root: string): void;
  onReact(message: HomeMessage, value: string): void;
  onEditStart?(message: HomeMessage): void;
  onEditEnd?(): void;
  /** My own messages: edit (resolves true when the owner took it) and delete. */
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
}

export const MessageRow = memo(function MessageRow({
  message,
  head,
  thread,
  people,
  me,
  strings,
  timeFormat,
  editing,
  onOpenThread,
  onReact,
  onEditStart,
  onEditEnd,
  onEdit,
  onRetract,
}: MessageRowProps) {
  const { t } = strings;
  const author = people.get(message.author);
  const time = timeFormat.format(message.createdAt);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const textOnly = message.parts.length > 0 && message.parts.every((part) => part.type === "text");
  const own = !message.retracted && message.author === me;
  const canEdit = own && textOnly && onEdit !== undefined && onEditStart !== undefined;
  return (
    <article
      className={`hc-msg${head ? " head" : ""}${mentionsMe(message, me) ? " mention" : ""}${editing ? " editing" : ""}`}
      aria-label={`${author?.name ?? message.author}, ${time}`}
    >
      <div className="hc-msg-gutter">
        {head ? <Avatar participant={author} size={36} /> : <time className="hc-msg-hover-time">{time}</time>}
      </div>
      <div className="hc-msg-main">
        {head && <Head author={author} fallback={message.author} time={time} strings={strings} />}
        {message.retracted ? (
          <p className="hc-msg-retracted">{t("message.retracted")}</p>
        ) : editing && onEdit ? (
          <Composer
            strings={strings}
            placeholder={t("action.edit")}
            label={t("action.edit")}
            initialValue={message.parts.map((part) => (part.type === "text" ? part.text : "")).join("\n")}
            focusOnOpen
            onCancel={() => onEditEnd?.()}
            onSend={async (text) => {
              const saved = await onEdit(message, text);
              if (saved) onEditEnd?.();
              return saved;
            }}
          />
        ) : (
          message.parts.map((part, index) => <Part key={index} part={part} strings={strings} />)
        )}
        {message.editedAt && !message.retracted && !editing && (
          <span className="hc-msg-edited">{t("message.edited")}</span>
        )}
        {message.reactions.length > 0 && <Reactions message={message} me={me} people={people} onReact={onReact} />}
        {thread && onOpenThread && (
          <ThreadLink thread={thread} people={people} strings={strings} onOpen={() => onOpenThread(message.id)} />
        )}
        {confirmDelete && onRetract && (
          <div className="hc-confirm" role="alert">
            <span>{t("delete.confirm")}</span>
            <button type="button" className="hc-text-button" onClick={() => setConfirmDelete(false)}>
              {t("edit.cancel")}
            </button>
            <button
              type="button"
              className="hc-text-button danger"
              onClick={() => {
                setConfirmDelete(false);
                onRetract(message);
              }}
            >
              {t("action.delete")}
            </button>
          </div>
        )}
      </div>
      {!message.retracted && !editing && (
        <MessageActions
          strings={strings}
          canEdit={canEdit}
          canDelete={own && onRetract !== undefined}
          onReact={(value) => onReact(message, value)}
          onReply={onOpenThread ? () => onOpenThread(message.id) : undefined}
          onEdit={() => onEditStart?.(message)}
          onDelete={() => setConfirmDelete(true)}
          onCopy={() => void navigator.clipboard?.writeText(messageText(message))}
        />
      )}
    </article>
  );
});

/** An agent's reply while it is written: grows in place, with no actions until it posts. */
export function DraftRow({
  draft,
  head,
  people,
  strings,
}: {
  draft: HomeDraft;
  head: boolean;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
}) {
  const author = people.get(draft.participant);
  const writing = <span className="hc-writing">{strings.t("draft.writing")}</span>;
  return (
    <article className={`hc-msg draft${head ? " head" : ""}`} aria-busy="true">
      <div className="hc-msg-gutter">{head && <Avatar participant={author} size={36} />}</div>
      <div className="hc-msg-main">
        {head && <Head author={author} fallback={draft.participant} time={writing} strings={strings} />}
        <Markdown className="hc-md">{draft.text}</Markdown>
        {!head && writing}
      </div>
    </article>
  );
}

function Head({
  author,
  fallback,
  time,
  strings,
}: {
  author?: HomeParticipant;
  fallback: string;
  time: ReactNode;
  strings: Strings;
}) {
  return (
    <header className="hc-msg-head">
      <span className="hc-msg-author">{author?.name ?? fallback}</span>
      {author?.chief && <span className="hc-tag">{strings.t("chief.badge")}</span>}
      {author?.kind === "agent" && !author.chief && <span className="hc-tag">{strings.t("agent.badge")}</span>}
      {typeof time === "string" ? <time className="hc-msg-time">{time}</time> : time}
    </header>
  );
}

function ThreadLink({
  thread,
  people,
  strings,
  onOpen,
}: {
  thread: ThreadSummary;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
  onOpen(): void;
}) {
  const { t, format } = strings;
  const stamp = new Intl.DateTimeFormat(strings.language, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
  const count = thread.count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(thread.count));
  return (
    <button type="button" className="hc-thread-link" onClick={onOpen}>
      <span className="hc-thread-faces" aria-hidden="true">
        {thread.authors.slice(0, 3).map((id) => (
          <Avatar key={id} participant={people.get(id)} size={20} />
        ))}
      </span>
      <span className="hc-thread-count">{count}</span>
      {thread.unread > 0 && (
        <span className="hc-thread-new">{strings.format("thread.new", String(thread.unread))}</span>
      )}
      <span className="hc-thread-last">{format("thread.lastReply", stamp.format(thread.lastAt))}</span>
      <span className="hc-thread-view">{t("thread.view")}</span>
      <span className="hc-thread-chevron" aria-hidden="true">
        <HomeIcon name="chevronRight" size={16} />
      </span>
    </button>
  );
}

function Part({ part, strings }: { part: HomePart; strings: Strings }) {
  switch (part.type) {
    case "text":
      return <Markdown className="hc-md">{part.text}</Markdown>;
    case "work":
      return (
        <div className={`hc-chip work ${part.status}`}>
          <span className="hc-chip-status">{strings.t(`work.${part.status}`)}</span>
          <span className="hc-chip-title">{part.title}</span>
          {part.preview && <span className="hc-chip-preview">{part.preview}</span>}
        </div>
      );
    case "attachment":
      return (
        <div className="hc-chip attachment">
          <span className="hc-chip-title">{part.name}</span>
          <span className="hc-chip-preview">{formatBytes(part.byteCount)}</span>
        </div>
      );
    case "other":
      return <p className="hc-msg-other">{part.text}</p>;
  }
}

function Reactions({
  message,
  me,
  people,
  onReact,
}: {
  message: HomeMessage;
  me?: string;
  people: ReadonlyMap<string, HomeParticipant>;
  onReact(message: HomeMessage, value: string): void;
}) {
  const counts = new Map<string, { authors: string[]; mine: boolean }>();
  for (const reaction of message.reactions) {
    const entry = counts.get(reaction.value) ?? { authors: [], mine: false };
    entry.authors.push(people.get(reaction.author)?.name ?? reaction.author);
    entry.mine = entry.mine || reaction.author === me;
    counts.set(reaction.value, entry);
  }
  return (
    <div className="hc-reactions">
      {[...counts].map(([value, entry]) => (
        <button
          key={value}
          type="button"
          className={`hc-reaction${entry.mine ? " mine" : ""}`}
          aria-pressed={entry.mine}
          title={entry.authors.join(", ")}
          onClick={() => onReact(message, value)}
        >
          <span>{value}</span>
          <span className="hc-reaction-count">{entry.authors.length}</span>
        </button>
      ))}
    </div>
  );
}

function formatBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}
