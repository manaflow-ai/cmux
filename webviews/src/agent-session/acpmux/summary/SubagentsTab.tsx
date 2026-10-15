// The summary card's Subagents tab (cx-x62ev, after the ChatGPT desktop app's right pane): the
// chat's subagents, nested ones included, under "Active · N" (or "No active subagents") and
// "Done · N", newest first. Each is the transcript's own subagent row (SubagentListRow), so it has
// the same avatar and state as in the chat; a row shows that subagent (`onOpen`): in a pane of its
// own beside the chat, or in this pane when none opens.
import React from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
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

function List({ title, agents }: { title: string; agents: readonly Subagent[] }) {
  return (
    <section className="acpmux-summary-section" aria-label={title}>
      <h3 className="acpmux-summary-title">{title}</h3>
      <div className="acpmux-summary-subagent-rows">
        {listRows(agents).map((row) => (
          <SubagentListRow key={row.id} row={row} />
        ))}
      </div>
    </section>
  );
}

export function SubagentsTab({
  agents,
  waiting,
  onOpen,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  onOpen: (id: string) => void;
}) {
  const t = useT();
  const newest = [...agents].sort((a, b) => b.startedAt - a.startedAt);
  const active = newest.filter((agent) => {
    const status = subagentStatus(agent, waiting);
    return status === "running" || status === "waiting";
  });
  const done = newest.filter((agent) => !active.includes(agent));
  return (
    <SubagentPaneContext.Provider value={onOpen}>
      {active.length > 0 ? (
        <List title={t("summary.subagents.active", { n: active.length })} agents={active} />
      ) : (
        <section className="acpmux-summary-section" aria-label={t("summary.subagents.noneActive")}>
          <h3 className="acpmux-summary-title">{t("summary.subagents.noneActive")}</h3>
        </section>
      )}
      {done.length > 0 && <List title={t("summary.subagents.ended", { n: done.length })} agents={done} />}
    </SubagentPaneContext.Provider>
  );
}
