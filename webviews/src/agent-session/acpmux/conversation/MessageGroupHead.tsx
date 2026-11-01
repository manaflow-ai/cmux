// The head of a folded group of messages from other sessions: the waiting group
// (PendingMessagesCard.tsx), a delivered inbox batch (LaneNoticeBatch.tsx) and an inbox notice of
// several threads (InboxNoticeCard.tsx). It is a sibling of the tool rows (Leo, 2026-11-01, on the
// old head, a bare chevron on a taller line: "let's just make this look better"): a tool row
// (conversation.css .cv-tool), its 22px height, gap and type, its glyph in the one icon column (the
// sender's harness mark, or the messages glyph when several sessions sent), the count as the
// summary, the senders muted and cut after it, then the chevron, shown and lit only while the row is
// hovered, focused or open. design/chat-transcript.md "One icon column".
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { ChevronRight } from "./icons";
import { SenderMark } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import { useInboxNoticeLook } from "./inboxNoticeLook";
import "./MessageGroupHead.css";

const ROW_ICON = rowIconSize(12);

/// The one sender of a group's messages, the one that best names its session and harness, or
/// nothing when two or more sessions sent (the head then draws the messages glyph).
export function groupSender(messages: readonly (IncomingMessage | undefined)[]): IncomingMessage | undefined {
  const known = messages.filter((message): message is IncomingMessage => Boolean(message));
  if (new Set(known.map((message) => message.name)).size !== 1) return undefined;
  return (
    [...known].reverse().find((message) => message.harness) ??
    [...known].reverse().find((message) => message.sessionId) ??
    known.at(-1)
  );
}

export function MessageGroupHead({
  sender,
  count,
  senders,
  open,
  bodyId,
  onToggle,
  className,
  iconClassName,
  ariaLabel,
}: {
  /// The group's one sender; none when several sessions sent.
  sender?: IncomingMessage;
  count: string;
  /// The senders' names, joined; muted after the count.
  senders?: string;
  open: boolean;
  bodyId: string;
  onToggle(): void;
  className?: string;
  iconClassName?: string;
  ariaLabel?: string;
}) {
  const look = useInboxNoticeLook();
  return (
    <button
      type="button"
      className={`cv-tool cv-message-group__head${className ? ` ${className}` : ""}`}
      data-look={look}
      data-find-skip=""
      aria-expanded={open}
      aria-controls={open ? bodyId : undefined}
      aria-label={ariaLabel}
      title={senders || undefined}
      onClick={onToggle}
    >
      <span className={`cv-tool__icon${iconClassName ? ` ${iconClassName}` : ""}`} aria-hidden="true">
        {sender ? <SenderMark message={sender} /> : <Icon name="agent.chat" size={ROW_ICON} row />}
      </span>
      <span className="cv-tool__text">
        <span className="cv-message-group__count">{count}</span>
        {senders && <span className="cv-message-group__senders">{senders}</span>}
      </span>
      <span className="cv-tool__chevron" aria-hidden="true">
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
      </span>
    </button>
  );
}
