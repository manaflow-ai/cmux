// The chats a turn's agent started, as one card at the end of that turn, after its reply (Claude
// Code desktop's Changes card): a compact row for each, its title over a status line that leads
// with the status (glyph and word in its colour) and then names its pull request, `· repo #N`, and
// one chevron. A row opens its chat. Its name in a reply draws as a chip that opens it too
// (StartedSessionChip), with its hover card (SessionHoverCard.tsx); a row has none, since it already
// says what the card would. Behind the `started-session-cards` experiment (startedSessions.ts).

import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { SenderIcon } from "../subagents/SenderIcon";
import { agentTone } from "../subagents/agentTones";
import { type SessionMention, type StartedSession, hasStatusLine, sessionStatus } from "./startedSessions";
import { SessionStatusLine } from "./SessionStatusLine";
import { useSessionHover } from "./useSessionHover";
import "./startedSessions.css";
import { openSessionAttributes } from "../conversation/menuParts";

/// The chats started in one turn, oldest first, as one card.
export function StartedSessionCards({
  started,
  onOpen,
}: {
  started: readonly StartedSession[];
  onOpen(sessionId: string): void;
}) {
  return (
    <div className="acpmux-started">
      {started.map((child) => (
        <StartedSessionCard key={child.sessionId} child={child} onOpen={onOpen} />
      ))}
    </div>
  );
}

/// A row's icon: Session Info's child chat rows' size (ChildSessionRows.tsx).
const ROW_ICON = rowIconSize(12);

export function StartedSessionCard({ child, onOpen }: { child: StartedSession; onOpen(sessionId: string): void }) {
  const status = sessionStatus(child.state, child.unread, child.pullRequests);
  return (
    <button
      type="button"
      className="acpmux-started-row"
      data-state={child.state}
      {...openSessionAttributes(child.sessionId)}
      onClick={() => onOpen(child.sessionId)}
    >
      {/* Its harness's mark, else the chat icon in its own stable tone, as Session Info's child chat
          rows draw it (ChildSessionRows.tsx), so the rows tell apart which agent runs each. */}
      <span className="acpmux-started-icon" aria-hidden>
        <SenderIcon harness={child.harness} tone={agentTone(child.sessionId)} size={ROW_ICON} fallback="agent.chat" />
      </span>
      <span className="acpmux-started-text">
        <span className="acpmux-started-title">{child.title}</span>
        {hasStatusLine(child) && (
          <SessionStatusLine status={status === "done" ? undefined : status} pullRequests={child.pullRequests} />
        )}
      </span>
      <Icon name="disclosure.collapsed" size={12} className="acpmux-started-chevron" />
    </button>
  );
}

/// A session's name or id in a reply: a chip that opens it, with its hover card.
export function StartedSessionChip({
  mention,
  text,
  onOpen,
}: {
  mention: SessionMention;
  text: string;
  onOpen(sessionId: string): void;
}) {
  const { trigger, card } = useSessionHover(mention.sessionId);
  return (
    <>
      <button
        {...trigger}
        type="button"
        className="acpmux-started-chip"
        data-state={mention.state}
        {...openSessionAttributes(mention.sessionId)}
        onClick={() => onOpen(mention.sessionId)}
      >
        {text}
      </button>
      {card}
    </>
  );
}
