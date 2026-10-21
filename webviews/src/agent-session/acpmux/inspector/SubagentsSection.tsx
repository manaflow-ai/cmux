// The Inspector's Subagents (after ChatGPT's pinned summary): one row of avatars, the harness's own
// subagents and the chats its agent started (ChildSessionRows.tsx; a Cloud VM's or another
// machine's included), the running ones first and breathing softly, with the live counts in the
// section's head ("3 running · 40 done"). A click on the row opens the list below it: Active, then
// Done, each subagent as the transcript draws it and each chat as its row (SubagentsTab.tsx); a
// subagent's row shows that subagent, a chat's opens that chat.
import { useState } from "react";
import { useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import type { StartedSession } from "../started/startedSessions";
import { Avatar, running } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { subagentStatus, type SubagentStatus } from "../summary/SubagentStatusList";
import { SubagentsTab } from "../summary/SubagentsTab";
import { sessionStatus } from "./ChildSessionRows";

/// Avatars drawn before "+N"; the row is one line at the Inspector's narrowest.
const SHOWN = 8;
const NO_SESSIONS: readonly StartedSession[] = [];

/// "1 waiting · 3 running · 40 done" for the section's head, the started chats counted with the
/// subagents, or nothing for neither.
export function subagentCounts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
): string {
  const count = (status: SubagentStatus) =>
    agents.filter((agent) => subagentStatus(agent, waiting) === status).length +
    sessions.filter((child) => sessionStatus(child) === status).length;
  return [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ]
    .filter(Boolean)
    .join(" · ");
}

/// A started chat's avatar: the chat icon, its dot in its state's color (subagents.css).
const SESSION_AVATAR: Record<SubagentStatus, string> = {
  running: "running",
  waiting: "running",
  failed: "failed",
  stopped: "cancelled",
  done: "completed",
};

export function SubagentsSection({
  agents,
  waiting,
  onOpen,
  sessions = NO_SESSIONS,
  onOpenSession,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  onOpen: (id: string) => void;
  /// The chats the agent started, and how one opens.
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
}) {
  const t = useT();
  const [listed, setListed] = useState(false);
  const total = agents.length + sessions.length;
  // Running ones lead the row; then the newest.
  const avatars = [
    ...agents.map((agent) => ({
      live: running(agent),
      at: agent.startedAt,
      avatar: <Avatar key={agent.id} agent={agent} dot />,
    })),
    ...sessions.map((child) => {
      const status = sessionStatus(child);
      return {
        live: status === "running" || status === "waiting",
        at: child.createdAt ?? 0,
        avatar: (
          <span key={child.sessionId} className="cv-subagent-avatar" data-state={SESSION_AVATAR[status]}>
            <Icon name="agent.chat" size={14} />
            <span className="cv-subagent-avatar__dot" aria-hidden="true" />
          </span>
        ),
      };
    }),
  ].sort((a, b) => Number(b.live) - Number(a.live) || b.at - a.at);
  const label = listed ? t("chatInspector.subagents.hide") : t("chatInspector.subagents.show", { n: total });
  return (
    <div className="acpmux-chat-inspector-subagents">
      <button
        type="button"
        className="acpmux-chat-inspector-avatars"
        aria-expanded={listed}
        aria-label={label}
        onClick={() => setListed(!listed)}
      >
        <span className="acpmux-chat-inspector-avatars__stack" aria-hidden="true">
          {avatars.slice(0, SHOWN).map((item) => item.avatar)}
        </span>
        {total > SHOWN && (
          <span className="acpmux-chat-inspector-avatars__more" aria-hidden="true">
            +{total - SHOWN}
          </span>
        )}
      </button>
      {listed && (
        <div className="acpmux-chat-inspector-scroll acpmux-chat-inspector-subagents__list">
          <SubagentsTab
            agents={agents}
            waiting={waiting}
            onOpen={onOpen}
            sessions={sessions}
            onOpenSession={onOpenSession}
          />
        </div>
      )}
    </div>
  );
}
