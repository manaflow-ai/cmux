// A chat this chat's agent started, as a card in the transcript (Claude Code desktop's linked
// session card, cmux-design-references apps/claude/live/transcript-linked-session-card.png):
// `title / what it does now  [PR 2 Ready]  •  ›`. The whole card opens the chat. Its name in a
// reply draws as a chip that opens it too (StartedSessionChip). Behind the
// `started-session-cards` experiment (startedSessions.ts).
import { createContext, useContext } from "react";
import { Icon } from "../icons/Icon";
import { useT, type StringKey, type Translate } from "../i18n";
import type { SessionMention, StartedPullRequests, StartedSession } from "./startedSessions";
import "./startedSessions.css";

const PR_WORDS: Record<StartedPullRequests["tone"], StringKey | undefined> = {
  ready: "started.prReady",
  failing: "started.prFailing",
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
  unknown: undefined,
};

/// The line under the title: the running chat's latest tool call, else what its state needs said.
export function startedLine(t: Translate, child: StartedSession): string | undefined {
  if (child.state === "running") return child.activity ? plainTitle(child.activity) : t("subagents.state.running");
  if (child.state === "waiting") return t("home.needsInput");
  if (child.state === "failed") return t("subagents.state.failed");
  return undefined;
}

/// A tool call's title without the backticks Claude puts around a command.
const plainTitle = (title: string) => title.replace(/^`([^`]*)`$/, "$1");

/// The cards of the chats started at one place in the transcript, oldest first.
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
  const t = useT();
  const line = startedLine(t, child);
  return (
    <button
      type="button"
      className="acpmux-started-card"
      data-state={child.state}
      data-unread={child.unread || undefined}
      onClick={() => onOpen(child.sessionId)}
    >
      <span className="acpmux-started-text">
        <span className="acpmux-started-title">{child.title}</span>
        {line && <span className="acpmux-started-line">{line}</span>}
      </span>
      {child.pullRequests && <PullRequestBadge pullRequests={child.pullRequests} />}
      <span className="acpmux-started-dot" aria-hidden="true" />
      <Icon name="disclosure.collapsed" size={12} className="acpmux-started-chevron" />
    </button>
  );
}

function PullRequestBadge({ pullRequests }: { pullRequests: StartedPullRequests }) {
  const t = useT();
  const word = PR_WORDS[pullRequests.tone];
  return (
    <span className="acpmux-started-prs" data-tone={pullRequests.tone}>
      <Icon name="git.pullrequest" size={12} />
      <span>{word ? `${pullRequests.count} ${t(word)}` : pullRequests.count}</span>
    </span>
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
      title={mention.title}
      onClick={() => onOpen(mention.sessionId)}
    >
      {text}
    </button>
  );
}
