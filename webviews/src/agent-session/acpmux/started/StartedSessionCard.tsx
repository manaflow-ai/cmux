// The chats a turn's agent started, as one card at the end of that turn, after its reply (Claude
// Code desktop's Changes card): a compact row for each, its title over a status line that leads
// with the status (glyph and word in its colour) and then names its pull request, `· repo #N`, and
// one chevron. A row opens its chat. Its name in a reply draws as a chip that opens it too
// (StartedSessionChip). Behind the `started-session-cards` experiment (startedSessions.ts).
import { createContext, useContext } from "react";
import { Icon } from "../icons/Icon";
import { type SessionMention, type StartedSession, hasStatusLine, sessionStatus } from "./startedSessions";
import { SessionStatusLine } from "./SessionStatusLine";
import "./startedSessions.css";

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

export function StartedSessionCard({ child, onOpen }: { child: StartedSession; onOpen(sessionId: string): void }) {
  const status = sessionStatus(child.state, child.unread, child.pullRequests);
  return (
    <button
      type="button"
      className="acpmux-started-row"
      data-state={child.state}
      onClick={() => onOpen(child.sessionId)}
    >
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

/// What a reply's name chips link: the chats the open chat started, and how to open one. Empty
/// with started session cards off, so a reply draws as it always did.
export type StartedMentions = { mentions: readonly SessionMention[]; open(sessionId: string): void };
export const NO_MENTIONS: StartedMentions = { mentions: [], open: () => undefined };
export const StartedMentionsContext = createContext<StartedMentions>(NO_MENTIONS);
export const useStartedMentions = () => useContext(StartedMentionsContext);

/// A started chat's name in a reply: a chip that opens it.
export function StartedSessionChip({
  mention,
  text,
  onOpen,
}: {
  mention: SessionMention;
  text: string;
  onOpen(sessionId: string): void;
}) {
  return (
    <button
      type="button"
      className="acpmux-started-chip"
      data-state={mention.state}
      onClick={() => onOpen(mention.sessionId)}
    >
      {text}
    </button>
  );
}
