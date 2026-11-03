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
import { useMessageLineLook } from "./messageLineLook";
import "./AgentMessageRow.css";
import "./MessageGroupHead.css";

const ROW_ICON = rowIconSize(12);

/// The one sender of a group's messages, the one that best names its session and harness, or
/// nothing when two or more sessions sent (the head then draws the messages glyph). A sender is its
/// session when one is known, else its name, as pendingMessages.ts `bySender` groups them; two
/// sessions that share a name are two senders, and so are two harnesses (cmux#30821).
export function groupSender(messages: readonly (IncomingMessage | undefined)[]): IncomingMessage | undefined {
  const known = messages.filter((message): message is IncomingMessage => Boolean(message));
  const senders = new Set(
    known.map((message) => (message.sessionId ? `session:${message.sessionId}` : `name:${message.name}`)),
  );
  if (senders.size !== 1) return undefined;
  if (new Set(known.flatMap((message) => (message.harness ? [message.harness] : []))).size > 1) return undefined;
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
  hint,
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
  /// The head's hover, when it is not `senders` (a "Received N messages" row's short names).
  hint?: string;
  open: boolean;
  bodyId: string;
  onToggle(): void;
  className?: string;
  iconClassName?: string;
  ariaLabel?: string;
}) {
  const look = useInboxNoticeLook();
  // Stacked (the default, messageLineLook.ts): the senders on their own line under the count, cut
  // there, as a message row's first line is; `quiet` keeps them in the tooltip only.
  const lineLook = useMessageLineLook();
  const below = lineLook === "stacked" && look !== "group-count" && !open ? senders : undefined;
  const inline = lineLook === "single" ? senders : undefined;
  return (
    <>
      <button
        type="button"
        className={`cv-tool cv-message-group__head${className ? ` ${className}` : ""}`}
        data-look={look}
        data-find-skip=""
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        aria-label={ariaLabel}
        title={hint || senders || undefined}
        onClick={onToggle}
      >
        <span className={`cv-tool__icon${iconClassName ? ` ${iconClassName}` : ""}`} aria-hidden="true">
          {sender ? <SenderMark message={sender} /> : <Icon name="agent.chat" size={ROW_ICON} row />}
        </span>
        <span className="cv-tool__text">
          <span className="cv-message-group__count">{count}</span>
          {inline && <span className="cv-message-group__senders">{inline}</span>}
        </span>
        <span className="cv-tool__chevron" aria-hidden="true">
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </span>
      </button>
      {below && (
        // The head's tooltip and label already name them; this line is for the eye and the pointer.
        // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
        <div className="cv-msgline__preview cv-message-group__below" aria-hidden data-find-skip="" onClick={onToggle}>
          {below}
        </div>
      )}
    </>
  );
}
