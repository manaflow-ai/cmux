// A Claude workflow's card in the transcript, where it started (Labs `workflowLabs`; the row is
// subagents/runningTray.ts `WORKFLOW_CARD`): its name, state, progress, current phase and latest
// line, live while it runs. A click opens Session Info's Background tasks, which lists its phases
// and agents (inspector/WorkflowTasks.tsx). Its height is fixed, so a clock or latest line never
// moves the transcript.
import { useMemo, useSyncExternalStore } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import type { WorkflowAgent } from "./workflow";
import { tally, workflowOf } from "./foldWorkflows";
import "./WorkflowCard.css";
import "./workflowDots.css";

/// Opens Session Info's Background tasks for workflow `id`; absent, the card is no button. The pane
/// sets it as its Inspector comes and goes (App.tsx), as subagents/runningTray.ts's switch is set.
let opener: ((id: string) => void) | undefined;
const listeners = new Set<() => void>();
export function configureWorkflowCardOpen(open: ((id: string) => void) | undefined): void {
  if (open === opener) return;
  opener = open;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => opener;

export type WorkflowCardPresentation = "selected" | "compact" | "phases";

const localizedState = (t: ReturnType<typeof useT>, state: WorkflowAgent["state"]): string => {
  switch (state) {
    case "running":
      return t("subagents.state.running");
    case "completed":
      return t("subagents.state.completed");
    case "failed":
      return t("subagents.state.failed");
    case "waiting":
      return t("subagents.state.waiting");
    case "paused":
      return t("goal.paused");
    case "cancelled":
      return t("subagents.state.cancelled");
    case "unknown":
      return t("inspector.unknown");
    default:
      return t("plan.status.pending");
  }
};

const compactTokens = (value: number) =>
  new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);

const latestAgentLine = (node: Subagent, agent: WorkflowAgent | undefined): string | undefined => {
  if (!agent) return undefined;
  // #26990 supplies `lastMessage` through foldWorkflows. Keep the fallback to the folded result
  // while that PR is in flight, then to the current action for older journals.
  const summaryAgent = agent as WorkflowAgent & { lastMessage?: string };
  const raw =
    agent.index === undefined || !(node.workflowAgents instanceof Map)
      ? undefined
      : node.workflowAgents.get(agent.index);
  return summaryAgent.lastMessage ?? raw?.result ?? agent.doing;
};

export function WorkflowCard({
  node,
  presentation = "selected",
}: {
  node: Subagent;
  presentation?: WorkflowCardPresentation;
}) {
  const t = useT();
  const open = useSyncExternalStore(subscribe, current, current);
  const workflow = useMemo(() => workflowOf(node, ""), [node]);
  const counts = tally(workflow.agents);
  const running = workflow.state === "running" && counts.running > 0;
  const now = useNow(running);
  const elapsed = workflow.elapsedMs ?? (workflow.startedAt !== undefined ? Math.max(0, now - workflow.startedAt) : 0);
  const reportedTotal = (workflow.counts?.started ?? 0) + (workflow.counts?.queued ?? 0);
  const total = Math.max(counts.total, reportedTotal);
  const done = Math.min(total, Math.max(counts.done, workflow.counts?.done ?? 0));
  const progress = total > 0 ? Math.min(1, done / total) : 0;
  const activeAgents = workflow.agents.filter((agent) => agent.state === "running" || agent.state === "paused");
  const focusAgent = activeAgents.at(-1) ?? workflow.agents.at(-1);
  const currentPhase =
    workflow.phases.find((phase) => phase.state === "running") ??
    (focusAgent ? workflow.phases.find((phase) => phase.agentIds.includes(focusAgent.id)) : undefined);
  const focusElapsed = focusAgent
    ? (focusAgent.elapsedMs ??
      (focusAgent.startedAt !== undefined ? Math.max(0, now - focusAgent.startedAt) : undefined))
    : undefined;
  const latest = latestAgentLine(node, focusAgent);
  const tokens = workflow.tokens ?? workflow.projectedTokens;
  return (
    <button
      type="button"
      className={`acpmux-workflow-card acpmux-workflow-card--${presentation}`}
      data-state={workflow.state}
      data-presentation={presentation}
      disabled={!open}
      onClick={() => open?.(node.id)}
    >
      <span className="acpmux-workflow-card__head">
        <span className="acpmux-workflow-card__name">{workflow.title}</span>
        <Icon name="disclosure.collapsed" size={11} />
      </span>
      <span className="acpmux-workflow-card__meta">
        <span>{localizedState(t, workflow.state)}</span>
        {currentPhase?.name && <span>{currentPhase.name}</span>}
        {total > 0 && (
          <span>
            {done}/{total}
          </span>
        )}
        <span>{formatDuration(elapsed)}</span>
        {tokens !== undefined && <span>{t("subagents.tokens", { n: tokens, tokens: compactTokens(tokens) })}</span>}
      </span>
      {presentation === "compact" ? (
        <span
          className="acpmux-workflow-card__progress"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a styled bar; <progress> cannot take the fill span.
          role="progressbar"
          aria-label={t("summary.subagents.done", { n: done })}
          aria-valuemin={0}
          aria-valuemax={total}
          aria-valuenow={done}
        >
          <span style={{ transform: `scaleX(${progress})` }} />
        </span>
      ) : presentation === "phases" ? (
        <span className="acpmux-workflow-card__phases" aria-label={currentPhase?.name}>
          {workflow.phases.map((phase) => (
            <span key={phase.id} data-state={phase.state} title={phase.name} />
          ))}
        </span>
      ) : (
        <>
          <span className="acpmux-workflow-card__latest" title={latest}>
            {latest ?? ""}
          </span>
          <span
            className="acpmux-workflow-card__progress"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a styled bar; <progress> cannot take the fill span.
            role="progressbar"
            aria-label={t("summary.subagents.done", { n: done })}
            aria-valuemin={0}
            aria-valuemax={total}
            aria-valuenow={done}
          >
            <span style={{ transform: `scaleX(${progress})` }} />
          </span>
          <span className="acpmux-workflow-card__focus">
            {focusAgent?.model && <span>{focusAgent.model}</span>}
            {focusElapsed !== undefined && <span>{formatDuration(focusElapsed)}</span>}
          </span>
        </>
      )}
    </button>
  );
}
