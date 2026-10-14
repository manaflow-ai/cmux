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
import { MAX_THREAD_INDENT, messageText, mentionsMe, type ThreadSummary } from "./model";
import type { PendingSend } from "./store";
import type { ThreadMeta } from "./threads";
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
  /** In a thread: reply to this message (threads nest without a limit). */
  onReply?(message: HomeMessage): void;
  onCopyLink?(message: HomeMessage): void;
  /** Indent level in the thread panel (0 = none). */
  depth?: number;
  /** The reply this one answers, named above it when the indent is capped. */
  parent?: HomeMessage;
  /** A link opened this message: it is marked (the timeline scrolls to it). */
  highlighted?: boolean;
  /** The keyboard cursor is on this message (j/k). */
  selected?: boolean;
  /** A root's thread as an object (title, status, owner). */
  meta?: ThreadMeta;
  /** The root's thread is open in place under it. */
  expanded?: boolean;
  /** Answers an agent's open question part. */
  onAnswer?(message: HomeMessage, partIndex: number, selections: Record<string, string>): void;
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
  onReply,
  onCopyLink,
  depth = 0,
  parent,
  highlighted = false,
  selected = false,
  meta,
  expanded = false,
  onAnswer,
}: MessageRowProps) {
  const { t, format } = strings;
  const author = people.get(message.author);
  const time = timeFormat.format(message.createdAt);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const textOnly = message.parts.length > 0 && message.parts.every((part) => part.type === "text");
  const own = !message.retracted && message.author === me;
  const canEdit = own && textOnly && onEdit !== undefined && onEditStart !== undefined;
  return (
    <article
      className={`hc-msg${head ? " head" : ""}${mentionsMe(message, me) ? " mention" : ""}${editing ? " editing" : ""}${highlighted ? " highlighted" : ""}${selected ? " selected" : ""}${depth > 0 ? " reply" : ""}${meta?.status === "resolved" ? " resolved" : ""}`}
      aria-label={`${author?.name ?? message.author}, ${time}`}
      aria-current={selected ? "true" : undefined}
      data-depth={depth > 0 ? Math.min(depth, MAX_THREAD_INDENT) : undefined}
      data-message={message.id}
    >
      <div className="hc-msg-gutter">
        {head ? (
          <Avatar participant={author} size={depth > 0 ? 24 : 36} />
        ) : (
          <time className="hc-msg-hover-time">{time}</time>
        )}
      </div>
      <div className="hc-msg-main">
        {parent && depth > MAX_THREAD_INDENT && (
          <p className="hc-msg-parent">
            {format("thread.inReplyTo", people.get(parent.author)?.name ?? parent.author)}
          </p>
        )}
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
          message.parts.map((part, index) => (
            <Part
              key={index}
              part={part}
              strings={strings}
              onAnswer={onAnswer ? (selections) => onAnswer(message, index, selections) : undefined}
            />
          ))
        )}
        {message.editedAt && !message.retracted && !editing && (
          <span className="hc-msg-edited">{t("message.edited")}</span>
        )}
        {message.reactions.length > 0 && <Reactions message={message} me={me} people={people} onReact={onReact} />}
        {thread && onOpenThread && (
          <ThreadChip
            thread={thread}
            meta={meta}
            expanded={expanded}
            people={people}
            strings={strings}
            onToggle={() => onOpenThread(message.id)}
          />
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
          onReply={
            onReply ? () => onReply(message) : onOpenThread ? () => onOpenThread(message.id) : undefined
          }
          replyLabel={onReply ? t("action.replyTo") : undefined}
          onCopyLink={onCopyLink ? () => onCopyLink(message) : undefined}
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
  const tag =
    author?.kind === "agent" ? strings.t(author.chief ? "chief.badge" : "agent.badge") : undefined;
  return (
    <header className="hc-msg-head">
      <span className="hc-msg-author">{author?.name ?? fallback}</span>
      {author && tag && !author.name.toLowerCase().includes(tag.toLowerCase()) && <span className="hc-tag">{tag}</span>}
      {typeof time === "string" ? <time className="hc-msg-time">{time}</time> : time}
    </header>
  );
}

/** A root's thread, closed or open in place: who replied, how many, the status and when. */
function ThreadChip({
  thread,
  meta,
  expanded,
  people,
  strings,
  onToggle,
}: {
  thread: ThreadSummary;
  meta?: ThreadMeta;
  expanded: boolean;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
  onToggle(): void;
}) {
  const { t, format } = strings;
  const count = thread.count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(thread.count));
  const resolved = meta?.status === "resolved";
  return (
    <button
      type="button"
      className={`hc-chip-thread${expanded ? " expanded" : ""}${resolved ? " resolved" : ""}`}
      aria-expanded={expanded}
      onClick={onToggle}
    >
      <span className="hc-thread-faces" aria-hidden="true">
        {thread.authors.slice(0, 3).map((id) => (
          <Avatar key={id} participant={people.get(id)} size={18} />
        ))}
      </span>
      <span className="hc-thread-count">{count}</span>
      {thread.unread > 0 && !expanded && (
        <span className="hc-thread-new">{format("thread.new", String(thread.unread))}</span>
      )}
      {resolved && (
        <span className="hc-thread-status">
          <HomeIcon name="check" size={13} />
          {t("thread.resolved")}
        </span>
      )}
      <span className="hc-thread-last">{expanded ? t("thread.collapse") : relative(thread.lastAt, strings)}</span>
    </button>
  );
}

/** "now", "5m", "3h", else the date: the chip's quiet age of the last reply. */
function relative(at: number, strings: Strings): string {
  const minutes = Math.round((Date.now() - at) / 60_000);
  const style = new Intl.RelativeTimeFormat(strings.language, { numeric: "auto", style: "narrow" });
  if (minutes < 1) return style.format(0, "second");
  if (minutes < 60) return style.format(-minutes, "minute");
  if (minutes < 24 * 60) return style.format(-Math.round(minutes / 60), "hour");
  return new Intl.DateTimeFormat(strings.language, { month: "short", day: "numeric" }).format(at);
}

/** My message the owner has not shown yet: the same shape, dimmed; Retry when it failed. */
export function PendingRow({
  pending,
  head,
  depth = 0,
  me,
  strings,
  onRetry,
  onDiscard,
}: {
  pending: PendingSend;
  head: boolean;
  depth?: number;
  me?: HomeParticipant;
  strings: Strings;
  onRetry(key: string): void;
  onDiscard(key: string): void;
}) {
  const { t } = strings;
  return (
    <article
      className={`hc-msg pending${head ? " head" : ""}${depth > 0 ? " reply" : ""}${pending.failed ? " failed" : ""}`}
      data-depth={depth > 0 ? Math.min(depth, MAX_THREAD_INDENT) : undefined}
      aria-busy={!pending.failed}
    >
      <div className="hc-msg-gutter">{head && <Avatar participant={me} size={depth > 0 ? 24 : 36} />}</div>
      <div className="hc-msg-main">
        {head && (
          <header className="hc-msg-head">
            <span className="hc-msg-author">{me?.name ?? ""}</span>
            {!pending.failed && <span className="hc-msg-time">{t("message.sending")}</span>}
          </header>
        )}
        <Markdown className="hc-md">{pending.text}</Markdown>
        {pending.failed && (
          <p className="hc-msg-failed" role="alert">
            <span>{t("message.failed")}</span>
            <button type="button" className="hc-link-button" onClick={() => onRetry(pending.key)}>
              {t("message.retry")}
            </button>
            <button type="button" className="hc-link-button" onClick={() => onDiscard(pending.key)}>
              {t("action.delete")}
            </button>
          </p>
        )}
      </div>
    </article>
  );
}

function Part({
  part,
  strings,
  onAnswer,
}: {
  part: HomePart;
  strings: Strings;
  onAnswer?(selections: Record<string, string>): void;
}) {
  switch (part.type) {
    case "question":
      return <Question part={part} strings={strings} onAnswer={onAnswer} />;
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

/** An agent's question: each prompt with its choices as quiet buttons; one press answers. */
function Question({
  part,
  strings,
  onAnswer,
}: {
  part: Extract<HomePart, { type: "question" }>;
  strings: Strings;
  onAnswer?(selections: Record<string, string>): void;
}) {
  const open = part.state === "pending" && onAnswer !== undefined;
  const single = part.items.length === 1;
  return (
    <div className={`hc-question ${part.state}`}>
      {part.items.map((item) => (
        <div key={item.id} className="hc-question-item">
          <p className="hc-question-prompt">{item.prompt}</p>
          {open && single && (
            <div className="hc-question-options">
              {item.options.map((option, index) => (
                <button
                  key={option.id}
                  type="button"
                  className={`hc-option${index === 0 ? " primary" : ""}`}
                  onClick={() => onAnswer?.({ [item.id]: option.id })}
                >
                  {option.label}
                </button>
              ))}
            </div>
          )}
        </div>
      ))}
      {part.state === "answered" && (
        <p className="hc-question-answer">
          <HomeIcon name="check" size={13} />
          {part.answer ? strings.format("question.answered", part.answer) : strings.t("question.done")}
        </p>
      )}
    </div>
  );
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
