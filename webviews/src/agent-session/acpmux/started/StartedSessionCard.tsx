// The chats a turn's agent started, as one card at the end of that turn, after its reply (Claude
// Code desktop's Changes card): a compact row for each, its title over a status line that leads
// with the status (glyph and word in its colour) and then names its pull request, `· repo #N`, and
// one chevron. A row opens its chat. Its name in a reply draws as a chip that opens it too
// (StartedSessionChip). Both show its hover card (SessionHoverCard.tsx). Behind the
// `started-session-cards` experiment (startedSessions.ts).
import { createContext, useContext } from "react";
import { Icon } from "../icons/Icon";
import { useT, type StringKey } from "../i18n";
import { Spinner } from "../conversation/icons";
import {
  type SessionMention,
  type SessionStatus,
  type StartedPullRequests,
  type StartedSession,
  hasStatusLine,
  sessionStatus,
} from "./startedSessions";
import { useSessionHover } from "./SessionHoverCard";
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
  const { trigger, card } = useSessionHover(child.sessionId);
  return (
    <>
      <button
        {...trigger}
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
      {card}
    </>
  );
}

/// Each status's word and glyph; running draws the bare working spinner instead.
const STATUS: Record<SessionStatus, { word: StringKey; glyph?: string }> = {
  waiting: { word: "home.needsInput", glyph: "status.needsinput" },
  failed: { word: "subagents.state.failed", glyph: "status.error" },
  running: { word: "subagents.state.running" },
  unread: { word: "sidebar.markUnread", glyph: "status.dot" },
  done: { word: "subagents.state.completed", glyph: "status.complete" },
  ready: { word: "started.prReady", glyph: "git.pullrequest" },
  failing: { word: "started.checksFailed", glyph: "git.pullrequest" },
  open: { word: "header.prBadge.open", glyph: "git.pullrequest" },
  draft: { word: "header.prBadge.draft", glyph: "git.pullrequest" },
  merged: { word: "header.prBadge.merged", glyph: "git.pullrequest" },
  closed: { word: "header.prBadge.closed", glyph: "git.pullrequest" },
};

/// `repo #N`, or `#N` when acpmux names no repository.
export const pullRequestName = (prs: StartedPullRequests): string =>
  prs.repo ? `${prs.repo} #${prs.number}` : `#${prs.number}`;

/// A session's status line, as Claude Code's PR rows read: the status first (its glyph and word in
/// its colour; a running one the bare working spinner), then `· repo #N` (and how many more) in
/// the dim colour. Without a status (a done chat on its card), only the pull request.
export function SessionStatusLine({
  status,
  pullRequests,
}: {
  status: SessionStatus | undefined;
  pullRequests?: StartedPullRequests | undefined;
}) {
  const t = useT();
  return (
    <span className="acpmux-session-status-line">
      {status && (
        <span className="acpmux-session-status" data-status={status}>
          {STATUS[status].glyph ? (
            <Icon name={STATUS[status].glyph!} size={11} />
          ) : (
            <Spinner size={11} className="acpmux-session-status-spinner" />
          )}
          <span>{t(STATUS[status].word)}</span>
        </span>
      )}
      {pullRequests && (
        <span className="acpmux-session-status-pr">
          <span>{pullRequestName(pullRequests)}</span>
          {pullRequests.count > 1 && <span>{t("started.morePullRequests", { count: pullRequests.count - 1 })}</span>}
        </span>
      )}
    </span>
  );
}

/// What a reply's name chips link: the chats the open chat started (by title and id) and every
/// other listed session (by its full id, sessionHover.ts `withSessionIds`), and how to open one. Empty
/// with started session cards off, so a reply draws as it always did.
export type StartedMentions = { mentions: readonly SessionMention[]; open(sessionId: string): void };
export const NO_MENTIONS: StartedMentions = { mentions: [], open: () => undefined };
export const StartedMentionsContext = createContext<StartedMentions>(NO_MENTIONS);
export const useStartedMentions = () => useContext(StartedMentionsContext);

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
        onClick={() => onOpen(mention.sessionId)}
      >
        {text}
      </button>
      {card}
    </>
  );
}
