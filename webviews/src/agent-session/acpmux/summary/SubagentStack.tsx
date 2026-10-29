import React, { memo } from "react";
import { useT } from "../i18n";
import type { SummarySubagent } from "./sessionSummary";
import { Avatar, STATE_LABEL } from "../subagents/SubagentGroup";
import { Icon } from "../icons/Icon";
import type { Subagent } from "../subagents/subagentFold";

/// Dots shown before the counts; the rest are counted, not drawn.
export const AGENT_STACK_LIMIT = 4;
const STACK = AGENT_STACK_LIMIT;
const NO_IDENTITIES: readonly string[] = [];

const DOT_STATE = { running: STATE_LABEL.running, done: STATE_LABEL.completed, failed: STATE_LABEL.failed } as const;

/// The compact stack used by summary surfaces that have the folded acpmux agent records. It keeps
/// the same overlap and tone treatment as the transcript summary stack, while retaining each
/// harness avatar when the full record is available.
export const AgentAvatarStack = memo(
  function AgentAvatarStack({
    agents,
    identities = NO_IDENTITIES,
  }: {
    agents: readonly Subagent[];
    /// Session/workflow IDs for the remaining avatar slots; no guessed harness identity.
    identities?: readonly string[];
  }) {
    return (
      <span className="acpmux-summary-stack acpmux-summary-stack--avatars" aria-hidden="true">
        {agents.slice(0, STACK).map((agent, index) => (
          <span key={agent.id} className="acpmux-summary-avatar" data-tone={index % STACK}>
            <Avatar agent={agent} />
          </span>
        ))}
        {identities.slice(0, Math.max(0, STACK - agents.length)).map((id) => (
          <span key={id} className="acpmux-summary-avatar">
            <span className="cv-subagent-avatar">
              <Icon name="agent.session" size={14} />
            </span>
          </span>
        ))}
      </span>
    );
  },
  (previous, next) => {
    const before = previous.agents.slice(0, STACK);
    const after = next.agents.slice(0, STACK);
    return (
      before.length === after.length &&
      (previous.identities ?? NO_IDENTITIES).slice(0, STACK - before.length).join("\0") ===
        (next.identities ?? NO_IDENTITIES).slice(0, STACK - after.length).join("\0") &&
      before.every(
        (agent, index) =>
          agent.id === after[index]!.id &&
          agent.state === after[index]!.state &&
          agent.harness === after[index]!.harness,
      )
    );
  },
);

/// The chat's subagents as one line: a dot per subagent, overlapping, then the counts by state
/// ("2 running · 19 done"). Each dot's tooltip names its subagent and its state, so the state is
/// never color alone (cx-sya4n); the counts carry it for VoiceOver.
export function SubagentStack({ subagents }: { subagents: readonly SummarySubagent[] }) {
  const t = useT();
  const count = (state: SummarySubagent["state"]) => subagents.filter((agent) => agent.state === state).length;
  const counts = [
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  return (
    <li className="acpmux-summary-row acpmux-summary-subagents">
      <span className="acpmux-summary-stack" aria-hidden="true">
        {subagents.slice(0, STACK).map((agent, index) => (
          <span
            key={agent.id}
            className="acpmux-summary-dot"
            data-state={agent.state}
            data-tone={index % STACK}
            title={`${agent.title} · ${t(DOT_STATE[agent.state])}`}
          />
        ))}
      </span>
      <span className="acpmux-summary-text">{counts.join(" · ")}</span>
    </li>
  );
}
