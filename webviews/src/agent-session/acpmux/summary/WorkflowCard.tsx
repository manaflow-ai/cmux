// A Claude workflow's card in the transcript, where it started (Labs `workflowLabs`; the row is
// subagents/runningTray.ts `WORKFLOW_CARD`): its name, state, every phase that runs now, what is
// done and running (a fraction only once no agent can still spawn), one clock, and a latest line in
// words (summary/workflowView.ts), live while it runs. A click opens Session Info's Background tasks, which lists its phases
// and agents (session-info/WorkflowTasks.tsx). Its height is fixed, so a clock or latest line never
// moves the transcript.
import { useMemo, useSyncExternalStore } from "react";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import type { WorkflowAgent } from "./workflow";
import { modelName, tally, workflowOf } from "./foldWorkflows";
import { cardCount, cardLine, listNames, runningPhases, workflowModel } from "./workflowView";
import "./WorkflowCard.css";
import "./workflowDots.css";
import { opener, sideTabOpener, listeners } from "./workflowCardModel";
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => opener;

const currentSideTab = () => sideTabOpener;

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
const ROW_ICON = rowIconSize(12);
const compactTokens = (value: number) =>
  new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
export function WorkflowCard({
  node,
  presentation = "selected",
}: {
  node: Subagent;
  presentation?: WorkflowCardPresentation;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const open = useSyncExternalStore(subscribe, current, current);
  const openSideTab = useSyncExternalStore(subscribe, currentSideTab, currentSideTab);
  const workflow = useMemo(() => workflowOf(node, ""), [node]);
  const counts = tally(workflow.agents);
  const running = workflow.state === "running" && counts.running > 0;
  // The card's one clock: the workflow's elapsed time (Leo's screenshot had a second, an agent's,
  // that disagreed with it).
  const now = useNow(running);
  const elapsed = workflow.elapsedMs ?? (workflow.startedAt !== undefined ? Math.max(0, now - workflow.startedAt) : 0);
  const count = cardCount(workflow);
  // The bar's scale: every agent known or reported started or queued, never only the ones seen.
  const total = count.total;
  const done = count.done;
  const progress = total > 0 ? Math.min(1, done / total) : 0;
  // Every phase that runs now: two can run at once.
  const phases = runningPhases(workflow);
  const phaseNames = phases.map((phase) => phase.name).filter(Boolean);
  const latest = cardLine(workflow);
  const model = workflowModel(workflow.agents);
  const tokens = workflow.tokens ?? workflow.projectedTokens;
  // While agents may still spawn, a fraction would read as the total: say what is done and running.
  const countText =
    count.kind === "progress"
      ? [
          count.done > 0 ? t("summary.subagents.done", { n: count.done }) : undefined,
          count.running > 0 ? t("summary.subagents.running", { n: count.running }) : undefined,
        ]
          .filter(Boolean)
          .join(" · ")
      : total > 0
        ? `${done}/${total}`
        : "";
  return (
    <div className="acpmux-workflow-card-wrap">
      <button
        type="button"
        className={`acpmux-workflow-card acpmux-workflow-card--${presentation}`}
        data-state={workflow.state}
        data-presentation={presentation}
        disabled={!open}
        onClick={(event) => open?.(node.id, event.currentTarget)}
      >
        <span className="acpmux-workflow-card__head">
          <span className="acpmux-workflow-card__name">{workflow.title}</span>
          <Icon name="disclosure.collapsed" size={ROW_ICON} row />
        </span>
        <span className="acpmux-workflow-card__meta">
          <span>{localizedState(t, workflow.state)}</span>
          {/* The selected card names its running phases on its last row, where they have room. */}
          {presentation !== "selected" && phaseNames.length > 0 && (
            <span className="acpmux-workflow-card__running">{listNames(phaseNames, language)}</span>
          )}
          {countText && <span>{countText}</span>}
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
          <span className="acpmux-workflow-card__phases" aria-label={listNames(phaseNames, language)}>
            {workflow.phases.map((phase) => (
              <span key={phase.id} data-state={phase.state} title={phase.name} />
            ))}
          </span>
        ) : (
          <>
            <span
              className="acpmux-workflow-card__latest"
              title={latest ? `${latest.agent}: ${latest.line}` : undefined}
            >
              {latest && (
                <>
                  <span className="acpmux-workflow-card__agent">{latest.agent}</span> {latest.line}
                </>
              )}
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
            {/* Every phase that runs now, then the workflow's model. */}
            <span className="acpmux-workflow-card__focus">
              {phaseNames.length > 0 && (
                <span className="acpmux-workflow-card__running">{listNames(phaseNames, language)}</span>
              )}
              {model && <span>{modelName(model)}</span>}
            </span>
          </>
        )}
      </button>
      {openSideTab && (
        <button
          type="button"
          className="acpmux-workflow-card__side-tab"
          aria-label={t("workflow.openInSideTab")}
          title={t("workflow.openInSideTab")}
          onClick={(event) => openSideTab(node.id, event.currentTarget)}
        >
          <Icon name="tunable.sidebar" size={12} />
        </button>
      )}
    </div>
  );
}
