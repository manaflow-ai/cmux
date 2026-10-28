// The compact Session Info summary for all agent work. It keeps the existing detailed lists below
// intact; clicking this card opens the matching detail section.
import { useMemo } from "react";
import { useT } from "../i18n";
import { AgentAvatarStack, AGENT_STACK_LIMIT } from "../summary/SubagentStack";
import { tally } from "../summary/foldWorkflows";
import type { WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import type { SubsessionRow } from "../subagents/subsessions";
import type { StartedSession } from "../started/startedSessions";
import { subagentTally, subsessionTally } from "./SubagentsSection";
import "./SubagentSummaryCard.css";

/// Shared input contract for Session Info, SummaryCard, and agent-mesh consumers.
/// Pass App.tsx's folded arrays; this component owns no subscriptions or agent state.
export type SubagentSummaryCardProps = {
  /// Ordinary subagents; workflow container nodes must be omitted when workflows is supplied.
  agents: readonly Subagent[];
  /// IDs of ordinary subagents waiting for input.
  waiting: ReadonlySet<string>;
  /// Existing started-chat records; omit any sessionId also present in subsessions.
  sessions: readonly StartedSession[];
  /// App.tsx chatSubsessions.rows, including nested rows.
  subsessions?: readonly SubsessionRow[];
  /// App.tsx workflows; callers must pass none when the workflow Labs gate is off.
  workflows?: readonly WorkflowSummary[];
  /// Reveal the host surface's existing detail. Absent for a read-only preview.
  onOpen?: () => void;
  /// Gallery alternatives; production uses the default line treatment.
  variant?: "line" | "segmented" | "chips";
  /// Gallery empty-state preview; production hides an empty card.
  showEmpty?: boolean;
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
}: SubagentSummaryCardProps) {
  const t = useT();
  // Only collect what the bounded avatar preview draws, even in a forty-agent workflow.
  const identities: string[] = [];
  const remaining = Math.max(0, AGENT_STACK_LIMIT - agents.length);
  for (const row of sessions) {
    if (identities.length >= remaining) break;
    identities.push(`started:${row.sessionId}`);
  }
  for (const row of subsessions) {
    if (identities.length >= remaining) break;
    identities.push(`session:${row.sessionId}`);
  }
  for (const workflow of workflows) {
    if (identities.length >= remaining) break;
    for (const agent of workflow.agents) {
      if (identities.length >= remaining) break;
      identities.push(`workflow:${workflow.id}:${agent.id}`);
    }
  }
  const counts = useMemo(() => {
    const source = subagentTally(agents, waiting, sessions);
    const sub = subsessionTally(subsessions);
    const result = {
      running: source.running + sub.running,
      queued: source.waiting + sub.waiting,
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
  const detail = runningWorkflow ? [runningWorkflow.title, runningPhase?.name].filter(Boolean).join(" · ") : undefined;
  if (total === 0 && !showEmpty) return null;
  return (
    <button
      type="button"
      className="acpmux-chat-inspector-agent-summary"
      aria-label={`${t("summary.subagents")} · ${labels.join(" · ")}`}
      onClick={onOpen}
      disabled={!onOpen}
    >
      <AgentAvatarStack agents={agents} identities={identities} />
      <span className="acpmux-chat-inspector-agent-summary__body">
        {variant === "line" && (
          <span className="acpmux-chat-inspector-agent-summary__counts">
            {labels.length > 0 ? labels.join(" · ") : t("summary.subagents.noneActive")}
          </span>
        )}
        {variant === "segmented" && (
          <>
            <span className="acpmux-chat-inspector-agent-summary__counts">{labels.join(" · ")}</span>
            <span className="acpmux-chat-inspector-agent-summary__bar" aria-label={labels.join(" · ")}>
              {countItems.map((item) => (
                <span key={item.key} data-status={item.key} style={{ flexGrow: item.count }} />
              ))}
            </span>
          </>
        )}
        {variant === "chips" && (
          <span className="acpmux-chat-inspector-agent-summary__chips">
            {countItems.map((item) => (
              <span key={item.key} data-status={item.key}>
                {item.text}
              </span>
            ))}
          </span>
        )}
        {detail && <span className="acpmux-chat-inspector-agent-summary__workflow">{detail}</span>}
      </span>
      <span className="acpmux-chat-inspector-agent-summary__chevron" aria-hidden="true">
        ›
      </span>
    </button>
  );
}
