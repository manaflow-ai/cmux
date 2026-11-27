// Workflow data comes from the fold; names/actions are supplied by the harness.
import { memo, useCallback, useContext, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useLiveUpdates } from "../../../ui/liveUpdates";
import { subscribePageDeadline } from "../../../ui/pageClock";
import { formatDuration } from "../conversation/turns";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { StateMark } from "./StateMark";
import { Elapsed } from "../subagents/Elapsed";
import { SubagentClockContext } from "../subagents/subagentGroupModel";
import {
  workflowDetailRequest,
  workflowSignals,
  workflowSignalBoundaries,
  type WorkflowDetailRequest,
  type WorkflowCapacitySignal,
} from "./foldWorkflows";
import type { WorkflowAgent, WorkflowSummary } from "./workflow";

export type WorkflowActions = {
  onPause?: () => void;
  onStop?: () => void;
  onSave?: () => void;
  onOpenTranscript?: (rowId: string) => void;
  onOpenAgent?: (agent: WorkflowAgent) => void;
  onPullAgent?: (request: WorkflowDetailRequest) => Promise<unknown>;
  onDraftWorkflow?: (resume: boolean) => boolean;
};

export const WorkflowSummaries = memo(function WorkflowSummaries({
  workflows = [],
  actionsFor,
  daemonCapacity,
}: {
  workflows?: readonly WorkflowSummary[];
  actionsFor?: (workflow: WorkflowSummary) => WorkflowActions;
  daemonCapacity?: WorkflowCapacitySignal;
}) {
  const t = useT();
  const capacity = workflows.some((workflow) => workflow.state === "running") ? daemonCapacity : undefined;
  const boundaries = useMemo(() => workflowSignalBoundaries(workflows, capacity), [workflows, capacity]);
  const now = useWorkflowSignalTime(boundaries);
  const signals = useMemo(() => workflowSignals(workflows, now, capacity), [workflows, now, capacity]);
  return (
    <>
      {signals.capacity && (
        <p className="acpmux-workflow__warning">
          <output>{t("workflow.capacity")}</output>
        </p>
      )}
      {workflows.map((workflow) => (
        <WorkflowSummaryRow
          key={workflow.id}
          workflow={workflow}
          actions={actionsFor?.(workflow)}
          idle={signals.idle}
          liveElapsed
        />
      ))}
    </>
  );
});

// Signal values are constant between boundaries. A boundary is on the session clock;
// the page scheduler takes wall time.
function useWorkflowSignalTime(boundaries: readonly number[]): number {
  const offset = useContext(SubagentClockContext);
  const active = useLiveUpdates();
  const position = useCallback(() => {
    const now = Date.now() - offset;
    let lo = 0;
    let hi = boundaries.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (boundaries[mid]! <= now) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }, [boundaries, offset]);
  const subscribe = useCallback(
    (notify: () => void) => {
      const next = () => (boundaries[position()] ?? Infinity) + offset;
      return active && Number.isFinite(next()) ? subscribePageDeadline(notify, next) : () => {};
    },
    [active, boundaries, offset, position],
  );
  const index = useSyncExternalStore(subscribe, position, position);
  return boundaries[index - 1] ?? -Infinity;
}

const localizedState = (
  t: ReturnType<typeof useT>,
  // Every phase and workflow state is an agent state too.
  state: WorkflowAgent["state"],
): string => {
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

export function WorkflowSummaryRow({
  workflow,
  actions = {},
  idle,
  now,
  liveElapsed = false,
}: {
  workflow?: WorkflowSummary;
  actions?: WorkflowActions;
  idle?: ReadonlySet<string>;
  now?: number;
  liveElapsed?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [resumeRefused, setResumeRefused] = useState(false);
  const [detail, setDetail] = useState<string>();
  const detailTicket = useRef(0);
  useEffect(
    () => () => {
      detailTicket.current += 1;
    },
    [],
  );
  const selectedAgentPhaseId = workflow?.selectedAgentId
    ? workflow.phases.find((entry) => entry.agentIds.includes(workflow.selectedAgentId!))?.id
    : undefined;
  const preferredPhaseId = workflow?.phase ?? selectedAgentPhaseId ?? workflow?.phases[0]?.id;
  const [phaseId, setPhaseId] = useState(preferredPhaseId);
  useEffect(() => setPhaseId(preferredPhaseId), [preferredPhaseId]);
  const phase = useMemo(
    () => workflow?.phases.find((entry) => entry.id === phaseId) ?? workflow?.phases[0],
    [phaseId, workflow],
  );
  if (!workflow) return null;
  const completed = workflow.counts?.done ?? workflow.agents.filter((agent) => agent.state === "completed").length;
  const total = workflow.counts?.started ?? workflow.agents.length;
  const elapsedMs =
    workflow.elapsedMs ??
    (workflow.state === "running" && workflow.startedAt !== undefined && now !== undefined
      ? Math.max(0, now - workflow.startedAt)
      : undefined);
  const selected = workflow.selectedAgentId
    ? workflow.agents.find((agent) => agent.id === workflow.selectedAgentId)
    : undefined;
  const workflowStateLabel = localizedState(t, workflow.state);
  const state =
    workflow.state === "running" ? <Spinner size={12} loading /> : <Icon name="agent.session" size={12} row />;
  const canPause = workflow.state === "running" && actions.onPause;
  const canStop = (workflow.state === "running" || workflow.state === "paused") && actions.onStop;
  const canSave = actions.onSave;
  const hasLifecycleAction = canPause || canStop || canSave;
  const controlsUnavailable = (workflow.state === "running" || workflow.state === "paused") && !hasLifecycleAction;
  return (
    <section className="acpmux-summary-section acpmux-workflow" aria-label={workflow.title} data-state={workflow.state}>
      <button
        type="button"
        className="acpmux-summary-row acpmux-summary-link acpmux-workflow__row"
        aria-expanded={open}
        onClick={() => {
          detailTicket.current += 1;
          setOpen(!open);
        }}
      >
        <span className="acpmux-workflow__icon" data-state={workflow.state}>
          {state}
        </span>
        <span className="acpmux-summary-text acpmux-workflow__title">{workflow.title}</span>
        {/* Running is the row's spinner, no word (Leo, 2026-11-23: "\"running\" doesn't need text"). */}
        <span className="acpmux-workflow__state" aria-label={`${workflow.title}: ${workflowStateLabel}`}>
          {workflow.state === "running" ? null : workflowStateLabel}
        </span>
        {workflow.phase && (
          <span className="acpmux-summary-meta">
            {workflow.phases.find((entry) => entry.id === workflow.phase)?.name}
          </span>
        )}
        <span className="acpmux-summary-meta">
          {total > 0 && `${completed}/${total}`}
          {elapsedMs !== undefined ? (
            ` · ${formatDuration(elapsedMs)}`
          ) : liveElapsed && workflow.state === "running" && workflow.startedAt !== undefined ? (
            <>
              {" · "}
              <Elapsed since={workflow.startedAt} />
            </>
          ) : null}
          {workflow.tokens !== undefined &&
            ` · ${t("subagents.tokens", { n: workflow.tokens, tokens: workflow.tokens })}`}
        </span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
      </button>
      {open && (
        <div className="acpmux-workflow__detail">
          {workflow.resumedFrom && (
            <p className="acpmux-summary-meta">
              {t("workflow.resumedFrom", { run: workflow.runId ?? workflow.resumedFrom })}
            </p>
          )}
          {workflow.projectedTokens !== undefined && (
            <p className="acpmux-summary-meta">{t("workflow.projectedTokens", { tokens: workflow.projectedTokens })}</p>
          )}
          {workflow.runId && !actions.onPullAgent && !actions.onOpenAgent && (
            <p className="acpmux-summary-meta">
              <output>{t("workflow.detailUnavailable")}</output>
            </p>
          )}
          {workflow.large && (
            <p className="acpmux-workflow__warning" role="alert">
              {t("workflow.large")}
            </p>
          )}
          <div className="acpmux-workflow__columns">
            <div className="acpmux-workflow__phases">
              <h4>{t("workflow.phases")}</h4>
              {workflow.phases.map((entry) => (
                <button
                  type="button"
                  key={entry.id}
                  className="acpmux-workflow__phase"
                  data-state={entry.state}
                  aria-pressed={entry.id === phase?.id}
                  onClick={() => setPhaseId(entry.id)}
                >
                  <span>{entry.name || t("workflow.unassigned")}</span>
                  <StateMark state={entry.state} label={localizedState(t, entry.state)} mark />
                </button>
              ))}
            </div>
            <div className="acpmux-workflow__agents">
              <h4>{phase?.name ?? t("summary.subagents.active", { n: workflow.agents.length })}</h4>
              <ul className="acpmux-workflow__agent-list" aria-label={phase?.name || t("workflow.unassigned")}>
                {(phase ? workflow.agents.filter((agent) => phase.agentIds.includes(agent.id)) : workflow.agents).map(
                  (agent) => (
                    <li
                      className="acpmux-workflow__agent"
                      key={agent.id}
                      data-state={agent.state}
                      data-selected={agent.id === selected?.id || undefined}
                      aria-current={agent.id === selected?.id ? "true" : undefined}
                    >
                      <span className="acpmux-workflow__agent-icon">
                        {agent.state === "running" ? (
                          <Spinner size={12} loading />
                        ) : (
                          <Icon name="agent.session" size={12} row />
                        )}
                      </span>
                      <span className="acpmux-summary-text">
                        <span>{agent.name}</span>
                        {agent.doing && <span className="acpmux-workflow__doing">{agent.doing}</span>}
                        {idle?.has(agent.id) && (
                          <output>
                            {t("workflow.idle", { action: agent.doing ?? workflow.action ?? t("inspector.unknown") })}
                          </output>
                        )}
                      </span>
                      <StateMark
                        className="acpmux-summary-meta"
                        state={agent.state}
                        label={localizedState(t, agent.state)}
                      />
                      {workflowDetailRequest(workflow, agent) && (
                        <button
                          type="button"
                          disabled={!actions.onPullAgent && !actions.onOpenAgent}
                          title={
                            !actions.onPullAgent && !actions.onOpenAgent ? t("workflow.detailUnavailable") : undefined
                          }
                          aria-label={`${t("transcript.label")}: ${agent.name}`}
                          onClick={() => {
                            if (actions.onOpenAgent) return actions.onOpenAgent(agent);
                            if (!actions.onPullAgent) return;
                            const request = workflowDetailRequest(workflow, agent)!;
                            const ticket = ++detailTicket.current;
                            void actions.onPullAgent!(request).then(
                              (value) => {
                                if (ticket === detailTicket.current)
                                  setDetail(typeof value === "string" ? value : JSON.stringify(value));
                              },
                              () => {
                                if (ticket === detailTicket.current) setDetail(t("inspector.unknown"));
                              },
                            );
                          }}
                        >
                          <Icon name="disclosure.collapsed" size={12} />
                        </button>
                      )}
                      {agent.transcriptRowId && actions.onOpenTranscript && (
                        <button
                          type="button"
                          className="acpmux-workflow__transcript"
                          aria-label={`${t("transcript.label")}: ${agent.name}`}
                          onClick={() => actions.onOpenTranscript?.(agent.transcriptRowId!)}
                        >
                          <Icon name="disclosure.collapsed" size={12} />
                        </button>
                      )}
                    </li>
                  ),
                )}
              </ul>
              {selected && <span className="acpmux-workflow__selected">{selected.name}</span>}
            </div>
          </div>
          {detail && <pre>{detail}</pre>}
          {actions.onDraftWorkflow &&
            (workflow.state === "paused" ||
              workflow.state === "cancelled" ||
              workflow.state === "failed" ||
              workflow.state === "unknown") && (
              <div className="acpmux-workflow__actions">
                {!resumeRefused && (
                  <button type="button" onClick={() => setResumeRefused(!actions.onDraftWorkflow!(true))}>
                    {t("composer.queueResume")}
                  </button>
                )}
                {resumeRefused && <output>{t("workflow.cannotResume")}</output>}
                <button type="button" onClick={() => actions.onDraftWorkflow!(false)}>
                  {/* retry-prompt-ok: drafts the whole workflow again, agents and paid model requests. */}
                  {t("workflow.runAgain")}
                </button>
              </div>
            )}
          {hasLifecycleAction && (
            <div className="acpmux-workflow__actions">
              {canPause && (
                <button type="button" onClick={() => actions.onPause?.()}>
                  {t("replay.pause")}
                </button>
              )}
              {canStop && (
                <button type="button" onClick={() => actions.onStop?.()}>
                  {t("subagents.stop", { name: workflow.title })}
                </button>
              )}
              {canSave && (
                <button type="button" onClick={() => actions.onSave?.()}>
                  {t("artifact.save")}
                </button>
              )}
            </div>
          )}
          {controlsUnavailable && (
            <div className="acpmux-workflow__actions" aria-label={t("summary.subagents")}>
              <button type="button" disabled aria-disabled="true">
                {t("replay.pause")}
              </button>
              <button type="button" disabled aria-disabled="true">
                {t("subagents.stop", { name: workflow.title })}
              </button>
              <button type="button" disabled aria-disabled="true">
                {t("artifact.save")}
              </button>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
