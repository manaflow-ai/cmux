// The compact Session Info summary for all agent work. It keeps the existing detailed lists below
// intact; clicking this card opens the matching detail section.
import { useMemo } from "react";
import { useT } from "../i18n";
import { AgentAvatarStack } from "../summary/SubagentStack";
import { tally } from "../summary/foldWorkflows";
import type { WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import type { SubsessionRow } from "../subagents/subsessions";
import type { StartedSession } from "../started/startedSessions";
import { sessionRetry } from "../subagents/retryState";
import { subagentTally } from "./SubagentsSection";
import "./SubagentSummaryCard.css";

type Props = {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  sessions: readonly StartedSession[];
  subsessions?: readonly SubsessionRow[];
  workflows?: readonly WorkflowSummary[];
  onOpen?: () => void;
  variant?: "line" | "segmented" | "chips";
  showEmpty?: boolean;
};

const countSubsessions = (rows: readonly SubsessionRow[]) => {
  const counts = { running: 0, queued: 0, done: 0, failed: 0 };
  for (const row of rows) {
    const retry = sessionRetry(row);
    if (retry.kind === "retrying" || row.state === "working") counts.running += 1;
    else if (row.state === "input" || row.slot) counts.queued += 1;
    else if (row.state === "done") counts.done += 1;
    else counts.failed += 1;
  }
  return counts;
};

export function SubagentSummaryCard({
  agents,
  waiting,
  sessions,
  subsessions = [],
  workflows = [],
  onOpen,
  variant = "line",
  showEmpty = false,
}: Props) {
  const t = useT();
  const counts = useMemo(() => {
    const source = subagentTally(agents, waiting, sessions);
    const sub = countSubsessions(subsessions);
    const result = {
      running: source.running + sub.running,
      queued: source.waiting + sub.queued,
      done: source.done + sub.done,
      failed: source.failed + source.stopped + sub.failed,
    };
    for (const workflow of workflows) {
      const tallyResult = tally(workflow.agents);
      result.running += tallyResult.running;
      result.queued += tallyResult.queued;
      result.done += tallyResult.done;
      result.failed += tallyResult.failed;
    }
    return result;
  }, [agents, waiting, sessions, subsessions, workflows]);
  const total = counts.running + counts.queued + counts.done + counts.failed;
  const countItems = [
    { key: "running", text: t("summary.subagents.running", { n: counts.running }), count: counts.running },
    { key: "queued", text: t("workflow.queued", { n: counts.queued }), count: counts.queued },
    { key: "done", text: t("summary.subagents.done", { n: counts.done }), count: counts.done },
    { key: "failed", text: t("summary.subagents.failed", { n: counts.failed }), count: counts.failed },
  ].filter((item) => item.count > 0);
  const labels = countItems.map((item) => item.text);
  const runningWorkflow = workflows.find((workflow) => workflow.state === "running");
  const runningPhase = runningWorkflow?.phases.find((phase) => phase.state === "running");
  const detail = runningWorkflow
    ? [runningWorkflow.title, runningPhase?.name].filter(Boolean).join(" · ")
    : undefined;
  if (total === 0 && !showEmpty) return null;
  return (
    <button
      type="button"
      className="acpmux-chat-inspector-agent-summary"
      aria-label={`${t("summary.subagents")} · ${labels.join(" · ")}`}
      onClick={onOpen}
      disabled={!onOpen}
    >
      <AgentAvatarStack agents={agents} />
      <span className="acpmux-chat-inspector-agent-summary__body">
        {variant === "line" && (
          <span className="acpmux-chat-inspector-agent-summary__counts">
            {labels.length > 0 ? labels.join(" · ") : "No agents yet"}
          </span>
        )}
        {variant === "segmented" && (
          <span className="acpmux-chat-inspector-agent-summary__bar" aria-label={labels.join(" · ")}>
            {countItems.map((item) => (
              <span key={item.key} data-status={item.key} style={{ flexGrow: item.count }} />
            ))}
          </span>
        )}
        {variant === "chips" && (
          <span className="acpmux-chat-inspector-agent-summary__chips">
            {countItems.map((item) => (
              <span key={item.key} data-status={item.key}>{item.text}</span>
            ))}
          </span>
        )}
        {detail && <span className="acpmux-chat-inspector-agent-summary__workflow">{detail}</span>}
      </span>
      <span className="acpmux-chat-inspector-agent-summary__chevron" aria-hidden="true">›</span>
    </button>
  );
}
