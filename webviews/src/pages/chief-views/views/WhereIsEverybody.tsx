// Where is everybody: every agent and session on every machine, one row each, grouped by machine
// (this Mac first). The Lanes view of the Agent Activity page (#20363) moved beside the Chief:
// the same order (what needs you first) and the same filter, plus each agent's folder, the time
// since its last output and its pull request.
import { useMemo, useState } from "react";
import { branchPRs, byMachine, stateCounts } from "../model";
import { AgentRow, agentsOf, Loaded, machineLabel, stateKey, StateMark } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { AgentState } from "../types";

const STATES: AgentState[] = ["waiting", "failed", "working", "idle"];

export function WhereIsEverybodyView({ data, strings, now, placement, onOpenAgent }: ChiefViewProps) {
  const [filter, setFilter] = useState("");
  const agents = agentsOf(data);
  const prs = useMemo(() => branchPRs(data.fleet.status === "ready" ? data.fleet.reply.prs : undefined), [data.fleet]);
  const groups = useMemo(() => byMachine(agents, filter), [agents, filter]);
  const counts = useMemo(() => stateCounts(agents), [agents]);
  const compact = placement === "sidebar";
  return (
    <div className="cv-everybody">
      <div className="cv-toolbar">
        <ul className="cv-counts">
          {STATES.map((state) => (
            <li key={state} className="cv-count" data-state={state} data-zero={counts[state] ? undefined : ""}>
              <StateMark state={state} strings={strings} />
              <span className="cv-count-label">{strings.t(stateKey(state))}</span>
              <span className="cv-count-value">{counts[state]}</span>
            </li>
          ))}
        </ul>
        <input
          className="cv-filter"
          type="search"
          value={filter}
          placeholder={strings.t("chiefViews.filter.placeholder")}
          aria-label={strings.t("chiefViews.filter.placeholder")}
          onChange={(event) => setFilter(event.currentTarget.value)}
        />
      </div>
      <Loaded status={data.agents.status} strings={strings}>
        {agents.length === 0 ? (
          <p className="cv-note">{strings.t("chiefViews.agents.empty")}</p>
        ) : groups.length === 0 ? (
          <p className="cv-note">{strings.t("chiefViews.agents.noMatch")}</p>
        ) : (
          groups.map((group) => (
            <section key={group.id} className="cv-machine" aria-label={machineLabel(group.agents[0]!, strings)}>
              <h3 className="cv-machine-head">
                <span className="cv-machine-name">{machineLabel(group.agents[0]!, strings)}</span>
                <span className="cv-machine-count">{group.agents.length}</span>
                {group.attention > 0 && <span className="cv-machine-attention">{group.attention}</span>}
              </h3>
              <ul className="cv-rows">
                {group.agents.map((agent) => (
                  <AgentRow
                    key={`${agent.kind}:${agent.id}`}
                    agent={agent}
                    now={now}
                    strings={strings}
                    compact={compact}
                    prs={prs}
                    onOpen={onOpenAgent}
                  />
                ))}
              </ul>
            </section>
          ))
        )}
      </Loaded>
    </div>
  );
}
