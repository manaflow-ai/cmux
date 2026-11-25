import React from "react";
import { useT } from "../i18n";
import type { SummarySubagent } from "./sessionSummary";
import { STATE_LABEL } from "../subagents/subagentGroupModel";
import { orderedCountParts } from "../session-info/subagentsSectionModel";
import { CountLine } from "./LiveCount";

/// Dots shown before the counts; the rest are counted, not drawn.
const STACK = 4;

const DOT_STATE = { running: STATE_LABEL.running, done: STATE_LABEL.completed, failed: STATE_LABEL.failed } as const;

/// The chat's subagents as one line: a dot per subagent, overlapping, then the counts by state
/// ("1 failed · 19 done" in the shared order, the running ones as the subagents' mark and their number,
/// no word: LiveCount.tsx). Each dot's tooltip names its subagent and its state, so the state is never
/// color alone (cx-sya4n); the counts carry it for VoiceOver.
export function SubagentStack({ subagents }: { subagents: readonly SummarySubagent[] }) {
  const t = useT();
  const count = (state: SummarySubagent["state"]) => subagents.filter((agent) => agent.state === state).length;
  const counts = orderedCountParts({ failed: count("failed"), running: count("running"), done: count("done") }, t);
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
      <span className="acpmux-summary-text">
        <CountLine parts={counts} />
      </span>
    </li>
  );
}
