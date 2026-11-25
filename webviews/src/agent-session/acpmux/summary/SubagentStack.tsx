import React from "react";
import { useT } from "../i18n";
import type { SummarySubagent } from "./sessionSummary";
import { STATE_LABEL } from "../subagents/subagentGroupModel";
import { CountLine } from "./LiveCount";
import { countParts, live } from "./countParts";

/// Dots shown before the counts; the rest are counted, not drawn.
const STACK = 4;

const DOT_STATE = { running: STATE_LABEL.running, done: STATE_LABEL.completed, failed: STATE_LABEL.failed } as const;

/// The chat's subagents as one line: a dot per subagent, overlapping, then the counts by state
/// (the running ones as the subagents' mark and their number, no word: LiveCount.tsx; "19 done"). Each
/// dot's tooltip names its subagent and its state, so the state is never color alone (cx-sya4n); the
/// counts carry it for VoiceOver.
export function SubagentStack({ subagents }: { subagents: readonly SummarySubagent[] }) {
  const t = useT();
  const count = (state: SummarySubagent["state"]) => subagents.filter((agent) => agent.state === state).length;
  const counts = countParts(
    live(count("running"), t("summary.subagents.running", { n: count("running") })),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  );
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
