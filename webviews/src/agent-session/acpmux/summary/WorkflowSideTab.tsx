// The Labs-only full-height workflow view opened from a transcript card's side-tab action.
// It stays in the chat webview so it can consume the same folded workflow snapshot as Session Info.
import { formatDuration } from "../conversation/turns";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { StateMark } from "./StateMark";
import { rowIconSize } from "../icons/iconSize";
import { phaseAgents, tally } from "./foldWorkflows";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "./workflow";
import { Elapsed } from "../subagents/Elapsed";
import { WorkflowAgentRow } from "../session-info/WorkflowTasks";
import { StopButton } from "../session-info/TasksSection";
import "./WorkflowSideTab.css";
import { Clock } from "../../../ui/Typography";

export type WorkflowSideTabLayout = "timeline" | "lanes" | "table";

type Props = {
  workflow: WorkflowSummary;
  onClose: () => void;
  onStop?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  layout?: WorkflowSideTabLayout;
};

const running = (workflow: WorkflowSummary) => workflow.state === "running";
const ROW_ICON = rowIconSize(12);

function stateLabel(t: ReturnType<typeof useT>, state: WorkflowAgent["state"]): string {
  switch (state) {
    case "running":
      return t("subagents.state.running");
    case "completed":
      return t("subagents.state.completed");
    case "failed":
      return t("subagents.state.failed");
    case "cancelled":
      return t("subagents.state.cancelled");
    case "paused":
      return t("goal.paused");
    case "waiting":
      return t("subagents.state.waiting");
    default:
      return t("plan.status.pending");
  }
}

function phaseLabel(t: ReturnType<typeof useT>, phase: WorkflowPhase): string {
  return phase.name || t("workflow.unassigned");
}

function PhaseAgents({
  workflow,
  phase,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  phase: WorkflowPhase;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
}) {
  const agents = phaseAgents(workflow, phase);
  return (
    <ul className="acpmux-workflow-side-tab__agents">
      {agents.map((agent) => (
        <WorkflowAgentRow
          key={agent.id}
          workflow={workflow}
          agent={agent}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          variant="compact"
        />
      ))}
    </ul>
  );
}

function Timeline({
  workflow,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
}) {
  const t = useT();
  return (
    <ol className="acpmux-workflow-side-tab__timeline">
      {workflow.phases.map((phase) => {
        const counts = tally(phaseAgents(workflow, phase));
        return (
          <li key={phase.id} className="acpmux-workflow-side-tab__phase" data-state={phase.state}>
            <div className="acpmux-workflow-side-tab__phase-marker" aria-hidden="true">
              {phase.state === "running" ? (
                <Spinner size={ROW_ICON} loading />
              ) : (
                <Icon
                  name={
                    phase.state === "completed"
                      ? "status.complete"
                      : phase.state === "failed"
                        ? "status.error"
                        : "agent.session"
                  }
                  size={ROW_ICON}
                  row
                />
              )}
            </div>
            <div className="acpmux-workflow-side-tab__phase-body">
              <div className="acpmux-workflow-side-tab__phase-head">
                <strong>{phaseLabel(t, phase)}</strong>
                <span>
                  {counts.done}/{counts.total}
                </span>
              </div>
              <PhaseAgents workflow={workflow} phase={phase} onOpenWorkflowAgent={onOpenWorkflowAgent} />
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function Lanes({
  workflow,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
}) {
  const t = useT();
  return (
    <div className="acpmux-workflow-side-tab__lanes">
      {workflow.phases.map((phase) => (
        <section key={phase.id} className="acpmux-workflow-side-tab__lane" data-state={phase.state}>
          <header>
            <span>{phaseLabel(t, phase)}</span>
            <StateMark state={phase.state} label={stateLabel(t, phase.state)} mark />
          </header>
          <PhaseAgents workflow={workflow} phase={phase} onOpenWorkflowAgent={onOpenWorkflowAgent} />
        </section>
      ))}
    </div>
  );
}

function Table({
  workflow,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
}) {
  const t = useT();
  return (
    <table className="acpmux-workflow-side-tab__table" aria-label={t("workflow.phases")}>
      <thead>
        <tr className="acpmux-workflow-side-tab__table-head">
          <th scope="col">{t("workflow.phases")}</th>
          <th scope="col">{t("subagents.pill", { n: workflow.agents.length })}</th>
          <th scope="col">{t("workflow.state")}</th>
        </tr>
      </thead>
      <tbody>
        {workflow.phases.flatMap((phase) =>
          phaseAgents(workflow, phase).map((agent) => (
            <tr className="acpmux-workflow-side-tab__table-row" key={agent.id}>
              <td>{phaseLabel(t, phase)}</td>
              <td>
                <ul className="acpmux-workflow-side-tab__agents">
                  <WorkflowAgentRow
                    workflow={workflow}
                    agent={agent}
                    onOpenWorkflowAgent={onOpenWorkflowAgent}
                    variant="grid"
                  />
                </ul>
              </td>
              <td>
                <StateMark state={agent.state} label={stateLabel(t, agent.state)} mark />
              </td>
            </tr>
          )),
        )}
      </tbody>
    </table>
  );
}

export function WorkflowSideTab({ workflow, onClose, onStop, onOpenWorkflowAgent, layout = "timeline" }: Props) {
  const t = useT();
  const counts = tally(workflow.agents);
  return (
    <aside
      className="acpmux-workflow-side-tab ui-glass"
      data-glass-level="popover"
      data-layout={layout}
      aria-label={workflow.title}
    >
      <header className="acpmux-workflow-side-tab__head">
        <div className="acpmux-workflow-side-tab__title">
          <Icon name="agent.session" size={ROW_ICON} row />
          <span>{t("workflow.kind")}</span>
          <strong>{workflow.title}</strong>
        </div>
        <button
          type="button"
          className="acpmux-workflow-side-tab__close"
          aria-label={t("workflow.closeSideTab")}
          title={t("workflow.closeSideTab")}
          onClick={onClose}
        >
          <Icon name="action.close" size={12} />
        </button>
      </header>
      <div className="acpmux-workflow-side-tab__body">
        <div className="acpmux-workflow-side-tab__summary">
          <span className="acpmux-workflow-side-tab__state" data-state={workflow.state}>
            {workflow.state === "running" ? (
              <Spinner size={ROW_ICON} loading />
            ) : (
              <Icon name={workflow.state === "completed" ? "status.complete" : "status.error"} size={ROW_ICON} row />
            )}
            <StateMark state={workflow.state} label={stateLabel(t, workflow.state)} />
          </span>
          {workflow.elapsedMs !== undefined || (running(workflow) && workflow.startedAt !== undefined) ? (
            <time>
              {workflow.elapsedMs !== undefined ? (
                <Clock text={formatDuration(workflow.elapsedMs)} />
              ) : (
                <Elapsed since={workflow.startedAt!} />
              )}
            </time>
          ) : null}
          <span>
            {counts.done}/{counts.total} {t("subagents.pill", { n: counts.total })}
          </span>
          {workflow.tokens !== undefined && (
            <span>{t("subagents.tokens", { n: workflow.tokens, tokens: workflow.tokens })}</span>
          )}
          {running(workflow) && onStop && <StopButton id={workflow.id} name={workflow.title} stop={onStop} />}
        </div>
        {workflow.description && <p className="acpmux-workflow-side-tab__description">{workflow.description}</p>}
        {layout === "lanes" ? (
          <Lanes workflow={workflow} onOpenWorkflowAgent={onOpenWorkflowAgent} />
        ) : layout === "table" ? (
          <Table workflow={workflow} onOpenWorkflowAgent={onOpenWorkflowAgent} />
        ) : (
          <Timeline workflow={workflow} onOpenWorkflowAgent={onOpenWorkflowAgent} />
        )}
      </div>
    </aside>
  );
}
