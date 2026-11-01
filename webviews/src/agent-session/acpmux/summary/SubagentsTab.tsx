// The summary card's Subagents tab (cx-x62ev, after the ChatGPT desktop app's right pane): the
// chat's subagents, nested ones included, under "Active · N" (or "No active subagents") and
// "Done · N", newest first. Each is the transcript's own subagent row (SubagentListRow), so it has
// the same avatar and state as in the chat; a row shows that subagent (`onOpen`): in a pane of its
// own beside the chat, or in this pane when none opens. The chats the agent started (`sessions`,
// session-info/ChildSessionRows.tsx) follow the subagents in each list, a waiting or running one under
// Active and the rest under Done; a row opens that chat (`onOpenSession`).
import React from "react";
import { useT } from "../i18n";
import { ChildSessionRows, sessionStatus } from "../session-info/ChildSessionRows";
import type { AcpmuxRow } from "../model";
import type { StartedSession } from "../started/startedSessions";
import { SubagentListRow, SubagentPaneContext } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { SUBAGENT_ROW } from "../subagents/subagentRows";
import { subagentStatus } from "./SubagentStatusList";

/// Subagent rows as SubagentListRow draws them; each carries its place in its list (`status`).
function listRows(agents: readonly Subagent[]): AcpmuxRow[] {
  return agents.map((agent, index) => ({
    id: `summary-subagent:${agent.id}`,
    version: 1,
    at: agent.startedAt,
    kind: SUBAGENT_ROW,
    subagents: [agent],
    status: agents.length === 1 ? "only" : index === 0 ? "first" : index === agents.length - 1 ? "last" : "middle",
  }));
}

const NO_SESSIONS: readonly StartedSession[] = [];

function List({
  title,
  agents,
  sessions,
  onOpenSession,
}: {
  title: string;
  agents: readonly Subagent[];
  sessions: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
}) {
  return (
    <section className="acpmux-summary-section" aria-label={title}>
      <h3 className="acpmux-summary-title">{title}</h3>
      {agents.length > 0 && (
        <div className="acpmux-summary-subagent-rows">
          {listRows(agents).map((row) => (
            <SubagentListRow key={row.id} row={row} />
          ))}
        </div>
      )}
      {sessions.length > 0 && (
        <ul className="acpmux-summary-list">
          <ChildSessionRows sessions={sessions} onOpen={onOpenSession} />
        </ul>
      )}
    </section>
  );
}

export function SubagentsTab({
  agents,
  waiting,
  onOpen,
  sessions = NO_SESSIONS,
  onOpenSession,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  onOpen: (id: string) => void;
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
}) {
  const t = useT();
  const newest = [...agents].sort((a, b) => b.startedAt - a.startedAt);
  const active = newest.filter((agent) => {
    const status = subagentStatus(agent, waiting);
    return status === "running" || status === "waiting";
  });
  const done = newest.filter((agent) => !active.includes(agent));
  const liveSessions = sessions.filter((child) => {
    const status = sessionStatus(child);
    return status === "running" || status === "waiting";
  });
  const endedSessions = sessions.filter((child) => !liveSessions.includes(child));
  const activeCount = active.length + liveSessions.length;
  const doneCount = done.length + endedSessions.length;
  return (
    <SubagentPaneContext.Provider value={onOpen}>
      {activeCount > 0 ? (
        <List
          title={t("summary.subagents.active", { n: activeCount })}
          agents={active}
          sessions={liveSessions}
          onOpenSession={onOpenSession}
        />
      ) : (
        <section className="acpmux-summary-section" aria-label={t("summary.subagents.noneActive")}>
          <h3 className="acpmux-summary-title">{t("summary.subagents.noneActive")}</h3>
        </section>
      )}
      {doneCount > 0 && (
        <List
          title={t("summary.subagents.ended", { n: doneCount })}
          agents={done}
          sessions={endedSessions}
          onOpenSession={onOpenSession}
        />
      )}
    </SubagentPaneContext.Provider>
  );
}
