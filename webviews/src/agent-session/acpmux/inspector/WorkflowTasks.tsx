// The chat's Claude workflows in the Inspector's Background tasks (Labs, `workflowLabs`): running
// ones first, then the finished ones, each read from the subagent fold (summary/foldWorkflows.ts).
// A workflow shows its name, how long it has run and Stop; a line of its agents' counts and tokens;
// its description; then its phases, each with its counts and a dot per agent, which opens into
// the phase's agents (model, a check and how long it took, or Queued). "Up next" names the phases
// no agent has started. A running agent is a spinner, never a pulsing dot.
import { useState } from "react";
import { compactTokens } from "../conversation/CompactionNote";
import { Spinner } from "../conversation/icons";
import { formatDuration } from "../conversation/turns";
import { useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import { modelName, phaseAgents, tally, upNext, type Tally } from "../summary/foldWorkflows";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "../summary/workflow";
import { StopButton } from "./TasksSection";
import "./inspector.css";
import "./WorkflowTasks.css";
import "../summary/workflowDots.css";

const ROW_ICON = rowIconSize(12);

const isRunning = (workflow: WorkflowSummary) => workflow.state === "running";

export function WorkflowTasks({
  workflows,
  onStop,
}: {
  workflows: readonly WorkflowSummary[];
  /// Stops a running workflow (its Claude task, `stop_task`); absent where the harness cannot.
  onStop?: (id: string) => Promise<unknown>;
}) {
  const t = useT();
  const running = workflows.filter(isRunning);
  const finished = workflows.filter((workflow) => !isRunning(workflow));
  const now = useNow(running.length > 0);
  return (
    <div className="acpmux-workflow-tasks">
      {/* A group's count only when both groups show: the section's own head already counts what runs. */}
      {running.length > 0 && finished.length > 0 && (
        <h4 className="acpmux-workflow-tasks__group">{t("rail.running", { count: running.length })}</h4>
      )}
      {running.map((workflow) => (
        <WorkflowTask key={workflow.id} workflow={workflow} now={now} onStop={onStop} />
      ))}
      {running.length > 0 && finished.length > 0 && (
        <h4 className="acpmux-workflow-tasks__group">{t("rail.finished", { count: finished.length })}</h4>
      )}
      {finished.map((workflow) => (
        <WorkflowTask key={workflow.id} workflow={workflow} now={now} />
      ))}
    </div>
  );
}

/// "1 running · 2 queued · 3 done": each count that is not zero.
function countLine(t: Translate, counts: Tally): string[] {
  return [
    counts.running > 0 && t("summary.subagents.running", { n: counts.running }),
    counts.queued > 0 && t("workflow.queued", { n: counts.queued }),
    counts.done > 0 && t("summary.subagents.done", { n: counts.done }),
    counts.failed > 0 && t("summary.subagents.failed", { n: counts.failed }),
  ].filter((part): part is string => typeof part === "string");
}

const tokensLabel = (t: Translate, tokens: number) =>
  t("subagents.tokens", { n: tokens, tokens: compactTokens(tokens) });

function WorkflowTask({
  workflow,
  now,
  onStop,
}: {
  workflow: WorkflowSummary;
  now: number;
  onStop?: (id: string) => Promise<unknown>;
}) {
  const t = useT();
  const running = isRunning(workflow);
  const counts = tally(workflow.agents);
  const elapsed =
    workflow.elapsedMs ?? (workflow.startedAt !== undefined ? Math.max(0, now - workflow.startedAt) : undefined);
  const tokens = workflow.tokens !== undefined ? [tokensLabel(t, workflow.tokens)] : [];
  // Running: what its agents do now. Finished: that it was a workflow, how it ended and its size.
  const meta = running
    ? [...countLine(t, counts), ...tokens]
    : [
        t("workflow.kind"),
        workflow.state === "completed" ? t("bgTask.state.completed") : stateWord(t, workflow.state),
        t("subagents.pill", { n: counts.total }),
        ...tokens,
      ];
  const next = running ? upNext(workflow) : [];
  // A running workflow lists the phases its agents started; the rest are Up next.
  const listed = running ? workflow.phases.filter((phase) => !next.includes(phase)) : workflow.phases;
  return (
    <section className="acpmux-workflow-task" data-state={workflow.state} aria-label={workflow.title}>
      <div className="acpmux-workflow-task__head">
        <span className="acpmux-workflow-task__name">{workflow.title}</span>
        {elapsed !== undefined && <span className="acpmux-chat-inspector-task__time">{formatDuration(elapsed)}</span>}
        {running && onStop && <StopButton id={workflow.id} name={workflow.title} stop={onStop} />}
      </div>
      {meta.length > 0 && <p className="acpmux-workflow-task__meta">{meta.join(" · ")}</p>}
      {workflow.description && (
        <p className="acpmux-workflow-task__description" title={workflow.description}>
          {workflow.description}
        </p>
      )}
      {listed.length > 0 && (
        <ul className="acpmux-chat-inspector-list acpmux-workflow-task__phases">
          {listed.map((phase) => (
            <WorkflowPhaseRow key={phase.id} workflow={workflow} phase={phase} now={now} running={running} />
          ))}
        </ul>
      )}
      {next.length > 0 && (
        <p className="acpmux-workflow-task__next">
          {t("workflow.upNext", { phases: next.map((phase) => phase.name).join(", ") })}
        </p>
      )}
    </section>
  );
}

function stateWord(t: Translate, state: WorkflowSummary["state"]): string {
  if (state === "failed") return t("subagents.state.failed");
  if (state === "cancelled") return t("subagents.state.cancelled");
  if (state === "paused") return t("goal.paused");
  return t("inspector.unknown");
}

function WorkflowPhaseRow({
  workflow,
  phase,
  now,
  running,
}: {
  workflow: WorkflowSummary;
  phase: WorkflowPhase;
  now: number;
  running: boolean;
}) {
  const t = useT();
  const agents = phaseAgents(workflow, phase);
  const counts = tally(agents);
  // A running workflow's phase that has agents running opens on its own, so live work is in view.
  const [open, setOpen] = useState(running && counts.running > 0);
  const label = running ? countLine(t, counts).join(" · ") : counts.total > 0 ? `${counts.done}/${counts.total}` : "";
  const models = new Set(agents.map((agent) => agent.model).filter((model): model is string => !!model));
  const shared = models.size === 1 ? [...models][0] : undefined;
  return (
    <li className="acpmux-workflow-phase" data-state={phase.state}>
      <button type="button" className="acpmux-workflow-phase__head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="acpmux-workflow-phase__name">{phase.name || t("workflow.unassigned")}</span>
        <span className="acpmux-chat-inspector-task__time">{label}</span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
      </button>
      {/* A dot per agent says at a glance what the counts beside the name say in words. */}
      <span className="acpmux-workflow-dots" aria-hidden="true">
        {agents.map((agent) => (
          <span key={agent.id} className="acpmux-workflow-dot" data-state={agent.state} />
        ))}
      </span>
      {open && agents.length > 0 && (
        <ul className="acpmux-chat-inspector-list acpmux-workflow-phase__agents">
          {shared && (
            <li className="acpmux-workflow-phase__model">{t("workflow.model", { model: modelName(shared) })}</li>
          )}
          {agents.map((agent) => (
            <WorkflowAgentRow key={agent.id} agent={agent} now={now} model={shared ? undefined : agent.model} />
          ))}
        </ul>
      )}
    </li>
  );
}

function WorkflowAgentRow({ agent, now, model }: { agent: WorkflowAgent; now: number; model?: string }) {
  const t = useT();
  const queued = agent.state === "waiting" || agent.state === "pending";
  const elapsed =
    agent.elapsedMs ??
    (agent.state === "running" && agent.startedAt !== undefined ? Math.max(0, now - agent.startedAt) : undefined);
  return (
    <li className="acpmux-chat-inspector-task acpmux-workflow-agent" data-state={agent.state}>
      <span className="acpmux-workflow-agent__icon">
        {agent.state === "running" ? (
          <Spinner size={ROW_ICON} loading />
        ) : agent.state === "completed" ? (
          <Icon name="status.complete" size={ROW_ICON} row />
        ) : agent.state === "failed" || agent.state === "cancelled" ? (
          <Icon name="status.error" size={ROW_ICON} row />
        ) : null}
      </span>
      <span className="acpmux-chat-inspector-task__command">
        {agent.name}
        {model && <span className="acpmux-workflow-agent__model"> · {modelName(model)}</span>}
      </span>
      <span className="acpmux-chat-inspector-task__time">
        {queued ? t("workflow.agentQueued") : elapsed !== undefined ? formatDuration(elapsed) : ""}
      </span>
    </li>
  );
}
