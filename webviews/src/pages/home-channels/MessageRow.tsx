// One timeline row: on the first message of a run an author head (avatar, name, Chief tag, time),
// then the body (the agent pane's Markdown renderer), work and attachment chips and reactions (a
// thread root shows as a ThreadRow in the timeline instead). The hover card (MessageActions) holds the
// row's actions; a delete asks once, inline. A running agent reply is a DraftRow: the same shape,
// with the text growing and a quiet "writing" mark instead of the time.
import { memo, useState, type ReactNode } from "react";
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";
import type { Strings } from "../shared/i18n";
import { CardScreenshot, MessageAttachments } from "./AttachmentViews";
import { Avatar } from "./Avatar";
import { Composer } from "./Composer";
import type { HomeDraft } from "./drafts";
import { MessageActions } from "./MessageActions";
import { MAX_THREAD_INDENT, messageText, mentionsMe } from "./model";
import { MessageRuns } from "./RunCard";
import type { HomeAttachment, HomeCard, HomeMessage, HomeParticipant, HomePart } from "./types";

export interface MessageRowProps {
  message: HomeMessage;
  head: boolean;
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
  /** The keyboard's current message (j/k): r, t, c and e act on it. */
  focused?: boolean;
  /** My send the owner has not shown yet: sending, or failed with Retry and Discard. */
  pending?: "sending" | "failed";
  onRetry?(): void;
  onDiscard?(): void;
}

export const MessageRow = memo(function MessageRow({
  message,
  head,
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
  focused = false,
  pending,
  onRetry,
  onDiscard,
}: MessageRowProps) {
  const { t, format } = strings;
  const author = people.get(message.author);
  const time = timeFormat.format(message.createdAt);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const textOnly = message.parts.length > 0 && message.parts.every((part) => part.type === "text");
  const own = !message.retracted && message.author === me && pending === undefined;
  const canEdit = own && textOnly && onEdit !== undefined && onEditStart !== undefined;
  const body = (
    <>
      <div className="hc-msg-gutter">
        {head ? <Avatar participant={author} size={20} /> : <time className="hc-msg-hover-time">{time}</time>}
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
          <>
            {message.parts.map((part, index) => (
              <Part key={index} part={part} conversation={message.conversation} strings={strings} />
            ))}
            {message.parts.some((part) => part.type === "attachment") && (
              <MessageAttachments
                conversation={message.conversation}
                parts={message.parts.filter((part): part is HomeAttachment => part.type === "attachment")}
                strings={strings}
              />
            )}
          </>
        )}
        {message.editedAt && !message.retracted && !editing && (
          <span className="hc-msg-edited">{t("message.edited")}</span>
        )}
        {pending === "sending" && <p className="lg-pending">{t("pending.sending")}</p>}
        {pending === "failed" && (
          <p className="lg-pending failed" role="alert">
            <span>{t("pending.failed")}</span>
            <button type="button" className="lg-link-button" onClick={onRetry}>
              {t("pending.retry")}
            </button>
            <button type="button" className="lg-link-button" onClick={onDiscard}>
              {t("pending.discard")}
            </button>
          </p>
        )}
        {!message.retracted && !editing && pending === undefined && <MessageRuns message={message} />}
        {message.reactions.length > 0 && <Reactions message={message} me={me} people={people} onReact={onReact} />}
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
    </>
  );
  return (
    <article
      className={`hc-msg lg-msg${head ? " head" : ""}${mentionsMe(message, me) ? " mention" : ""}${editing ? " editing" : ""}${highlighted ? " highlighted" : ""}${focused ? " focused" : ""}${pending ? ` pending ${pending}` : ""}`}
      aria-label={`${author?.name ?? message.author}, ${time}`}
      aria-current={focused ? "true" : undefined}
      data-depth={depth > 0 ? Math.min(depth, MAX_THREAD_INDENT) : undefined}
    >
      {/* One wrapper whether or not the actions show, so editing never remounts the body. */}
      <MessageActions
        active={!message.retracted && !editing && pending === undefined}
        strings={strings}
        canEdit={canEdit}
        canDelete={own && onRetract !== undefined}
        onReact={(value) => onReact(message, value)}
        onReply={onReply ? () => onReply(message) : onOpenThread ? () => onOpenThread(message.id) : undefined}
        replyLabel={onReply ? t("action.replyTo") : undefined}
        onCopyLink={onCopyLink ? () => onCopyLink(message) : undefined}
        onEdit={() => onEditStart?.(message)}
        onDelete={() => setConfirmDelete(true)}
        onCopy={() => void navigator.clipboard?.writeText(messageText(message))}
      >
        {body}
      </MessageActions>
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
    <article className={`hc-msg lg-msg draft${head ? " head" : ""}`} aria-busy="true">
      <div className="hc-msg-gutter">{head && <Avatar participant={author} size={20} />}</div>
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

function Part({ part, conversation, strings }: { part: HomePart; conversation: string; strings: Strings }) {
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
      // Shown together, after the text (MessageAttachments).
      return null;
    case "card":
      return <Card card={part} conversation={conversation} strings={strings} />;
    case "other":
      return <p className="hc-msg-other">{part.text}</p>;
  }
}

/** A Chief's card: a live browser step with its screenshot, a Secure Store sign-in ask, or next-step chips (shown, not sent from here). */
function Card({ card, conversation, strings }: { card: HomeCard; conversation: string; strings: Strings }) {
  const { t, format } = strings;
  switch (card.kind) {
    case "browser":
      return (
        <div className={`hc-chip hc-card browser${card.live ? " live" : ""}`}>
          <span className="hc-chip-status">{t(card.surface === "computer" ? "card.computer" : "card.browser")}</span>
          <span className="hc-chip-title">{card.step}</span>
          {card.image && <CardScreenshot conversation={conversation} image={card.image} alt={t("card.screenshot")} />}
        </div>
      );
    case "sign_in":
      return (
        <div className="hc-chip hc-card sign-in">
          <span className="hc-chip-status">{t("card.secureStore")}</span>
          <span className="hc-chip-title">{format("card.signIn", card.site)}</span>
        </div>
      );
    case "next_steps":
      return (
        <ul className="hc-card-choices" aria-label={t("card.nextSteps")}>
          {card.choices.map((choice) => (
            <li key={choice} className="hc-chip hc-card choice">
              <span className="hc-chip-title">{choice}</span>
            </li>
          ))}
        </ul>
      );
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
          // tooltip-allow: who reacted, shown nowhere else
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
