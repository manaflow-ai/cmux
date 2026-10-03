import React from "react";
import { t } from "../i18n";
import type { SummarySubagent } from "./sessionSummary";

/// Dots shown before the counts; the rest are counted, not drawn.
const STACK = 4;

/// The chat's subagents as one line: a dot per subagent, overlapping, then the counts by state
/// ("2 running · 19 done"). Each dot's tooltip names its subagent.
export function SubagentStack({ subagents }: { subagents: readonly SummarySubagent[] }) {
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
            title={agent.title}
          />
        ))}
      </span>
      <span className="acpmux-summary-text">{counts.join(" · ")}</span>
    </li>
  );
}
