import { useContext } from "react";
import { useT } from "../i18n";
import type { SummarySubagent } from "./sessionSummary";
import { STATE_LABEL, SubagentHarnessContext } from "../subagents/SubagentGroup";
import { AgentIdentity, SUBAGENT_FALLBACK } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import { ICON_FLOOR, rowIconSize } from "../icons/iconSize";

/// Harness marks shown before the counts; the rest are counted, not drawn.
const STACK = 4;
const MARK_SIZE = rowIconSize(ICON_FLOOR);

const MARK_STATE = { running: STATE_LABEL.running, done: STATE_LABEL.completed, failed: STATE_LABEL.failed } as const;

/// The chat's subagents as one line: their own overlapping marks, then the counts by state
/// ("2 running · 19 done"). Each mark's tooltip names its subagent and its state, so the state is
/// never color alone (cx-sya4n); the counts carry it for VoiceOver.
export function SubagentStack({ subagents }: { subagents: readonly SummarySubagent[] }) {
  const t = useT();
  const chatHarness = useContext(SubagentHarnessContext);
  const count = (state: SummarySubagent["state"]) => subagents.filter((agent) => agent.state === state).length;
  const counts = [
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  return (
    <li className="acpmux-summary-row acpmux-summary-subagents">
      <span className="acpmux-summary-stack" data-summary-stack aria-hidden="true">
        {subagents.slice(0, STACK).map((agent, index) => (
          <span
            key={agent.id}
            className="acpmux-summary-mark"
            data-state={agent.state}
            style={{ zIndex: STACK - index }}
            title={`${agent.title} · ${t(MARK_STATE[agent.state])}`}
          >
            <AgentIdentity
              harness={agent.harness ?? chatHarness}
              tone={agentTone(agent.id)}
              size={MARK_SIZE}
              fallback={SUBAGENT_FALLBACK}
              look="tint"
            />
          </span>
        ))}
      </span>
      <span className="acpmux-summary-text">{counts.join(" · ")}</span>
    </li>
  );
}
