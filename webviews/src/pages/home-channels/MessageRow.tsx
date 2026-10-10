// One compact timeline row: an author head (avatar, name, time) on the first message of a run,
// then the message body (the agent pane's Markdown renderer), work and attachment chips,
// reactions, and the thread summary. Hover shows Reply in thread and quick reactions.
import { memo, useState } from "react";
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { Composer } from "./Composer";
import { mentionsMe, type ThreadSummary } from "./model";
import type { HomeMessage, HomeParticipant, HomePart } from "./types";

const QUICK_REACTIONS = ["👍", "✅", "👀"];

export interface MessageRowProps {
  message: HomeMessage;
  head: boolean;
  thread?: ThreadSummary;
  author?: HomeParticipant;
  me?: string;
  strings: Strings;
  timeFormat: Intl.DateTimeFormat;
  onOpenThread?(root: string): void;
  onReact(message: HomeMessage, value: string): void;
  /** My own messages: edit (resolves true when the owner took it) and delete. */
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
}

export const MessageRow = memo(function MessageRow({
  message,
  head,
  thread,
  author,
  me,
  strings,
  timeFormat,
  onOpenThread,
  onReact,
  onEdit,
  onRetract,
}: MessageRowProps) {
  const { t, format } = strings;
  const time = timeFormat.format(message.createdAt);
  const [editing, setEditing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const textOnly = message.parts.length > 0 && message.parts.every((part) => part.type === "text");
  const own = !message.retracted && message.author === me;
  const canEdit = own && textOnly && onEdit !== undefined;
  return (
    <article className={`hc-msg${head ? " head" : ""}${mentionsMe(message, me) ? " mention" : ""}`}>
      <div className="hc-msg-gutter">
        {head ? <Avatar participant={author} size={32} /> : <time className="hc-msg-hover-time">{time}</time>}
      </div>
      <div className="hc-msg-main">
        {head && (
          <header className="hc-msg-head">
            <span className="hc-msg-author">{author?.name ?? message.author}</span>
            {author?.chief && <span className="hc-tag">{t("chief.badge")}</span>}
            <time className="hc-msg-time">{time}</time>
          </header>
        )}
        {message.retracted ? (
          <p className="hc-msg-retracted">{t("message.retracted")}</p>
        ) : editing && onEdit ? (
          <Composer
            className="hc-edit"
            placeholder={t("action.edit")}
            label={t("action.edit")}
            initialValue={message.parts.map((part) => (part.type === "text" ? part.text : "")).join("\n")}
            onCancel={() => setEditing(false)}
            onSend={async (text) => {
              const saved = await onEdit(message, text);
              if (saved) setEditing(false);
              return saved;
            }}
          />
        ) : (
          message.parts.map((part, index) => <Part key={index} part={part} strings={strings} />)
        )}
        {message.editedAt && !message.retracted && <span className="hc-msg-edited">{t("message.edited")}</span>}
        {message.reactions.length > 0 && <Reactions message={message} me={me} onReact={onReact} />}
        {thread && onOpenThread && (
          <button type="button" className="hc-thread-link" onClick={() => onOpenThread(message.id)}>
            {thread.count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(thread.count))}
          </button>
        )}
      </div>
      {!message.retracted && (
        <div className="hc-msg-actions" role="toolbar">
          {QUICK_REACTIONS.map((value) => (
            <button key={value} type="button" title={t("action.react")} onClick={() => onReact(message, value)}>
              {value}
            </button>
          ))}
          {onOpenThread && (
            <button type="button" title={t("action.reply")} onClick={() => onOpenThread(message.id)}>
              {t("action.reply")}
            </button>
          )}
          {canEdit && !editing && (
            <button type="button" title={t("action.edit")} onClick={() => setEditing(true)}>
              {t("action.edit")}
            </button>
          )}
          {own && onRetract && (
            <button
              type="button"
              className={confirmDelete ? "danger" : undefined}
              title={t("action.delete")}
              onMouseLeave={() => setConfirmDelete(false)}
              onClick={() => {
                if (!confirmDelete) return setConfirmDelete(true);
                setConfirmDelete(false);
                onRetract(message);
              }}
            >
              {t(confirmDelete ? "action.deleteConfirm" : "action.delete")}
            </button>
          )}
        </div>
      )}
    </article>
  );
});

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
  onReact,
}: {
  message: HomeMessage;
  me?: string;
  onReact(message: HomeMessage, value: string): void;
}) {
  const counts = new Map<string, { count: number; mine: boolean }>();
  for (const reaction of message.reactions) {
    const entry = counts.get(reaction.value) ?? { count: 0, mine: false };
    entry.count += 1;
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
          onClick={() => onReact(message, value)}
        >
          <span>{value}</span>
          <span className="hc-reaction-count">{entry.count}</span>
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
