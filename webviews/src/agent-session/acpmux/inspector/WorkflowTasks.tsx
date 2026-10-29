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

export type WorkflowAgentRowVariant = "compact" | "detail" | "grid";

export function WorkflowTasks({
  workflows,
  onStop,
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant = "detail",
}: {
  workflows: readonly WorkflowSummary[];
  /// Stops a running workflow (its Claude task, `stop_task`); absent where the harness cannot.
  onStop?: (id: string) => Promise<unknown>;
  /// Opens a Claude workflow agent by its transcript id through the native subagent pane path.
  onOpenSubagent?: (id: string) => void;
  /// Opens a workflow agent through the workflow transcript bridge.
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  /// Gallery-only row treatments; the shipped row uses the detail treatment.
  agentRowVariant?: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const running = workflows.filter(isRunning);
  const finished = workflows.filter((workflow) => !isRunning(workflow));
  // A running workflow's own elapsed time keeps moving even before its first agent event arrives
  // (or while all of its agents are queued). Finished workflows do not need a timer.
  const now = useNow(running.length > 0);
  return (
    <div className="acpmux-workflow-tasks">
      {/* A group's count only when both groups show: the section's own head already counts what runs. */}
      {running.length > 0 && finished.length > 0 && (
        <h4 className="acpmux-workflow-tasks__group">{t("rail.running", { count: running.length })}</h4>
      )}
      {running.map((workflow) => (
        <WorkflowTask
          key={workflow.id}
          workflow={workflow}
          now={now}
          onStop={onStop}
          onOpenSubagent={onOpenSubagent}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          agentRowVariant={agentRowVariant}
        />
      ))}
      {running.length > 0 && finished.length > 0 && (
        <h4 className="acpmux-workflow-tasks__group">{t("rail.finished", { count: finished.length })}</h4>
      )}
      {finished.map((workflow) => (
        <WorkflowTask
          key={workflow.id}
          workflow={workflow}
          now={now}
          onOpenSubagent={onOpenSubagent}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          agentRowVariant={agentRowVariant}
        />
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
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant,
}: {
  workflow: WorkflowSummary;
  now: number;
  onStop?: (id: string) => Promise<unknown>;
  onOpenSubagent?: (id: string) => void;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  agentRowVariant: WorkflowAgentRowVariant;
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
            <WorkflowPhaseRow
              key={phase.id}
              workflow={workflow}
              phase={phase}
              now={now}
              running={running}
              onOpenSubagent={onOpenSubagent}
              onOpenWorkflowAgent={onOpenWorkflowAgent}
              agentRowVariant={agentRowVariant}
            />
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
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant,
}: {
  workflow: WorkflowSummary;
  phase: WorkflowPhase;
  now: number;
  running: boolean;
  onOpenSubagent?: (id: string) => void;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  agentRowVariant: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const agents = phaseAgents(workflow, phase);
  const counts = tally(agents);
  // A running workflow's phase that has agents running opens on its own, so live work is in view.
  const [open, setOpen] = useState(running && counts.running > 0);
  const label = running ? countLine(t, counts).join(" · ") : counts.total > 0 ? `${counts.done}/${counts.total}` : "";
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
          {agents.map((agent) => (
            <WorkflowAgentRow
              key={agent.id}
              agent={agent}
              now={now}
              onOpenSubagent={onOpenSubagent}
              onOpenWorkflowAgent={onOpenWorkflowAgent}
              variant={agentRowVariant}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

/// A live workflow agent's state, model, elapsed time and latest action/message. Rows open through
/// the workflow bridge when one is supplied; without it they remain inert.
export function WorkflowAgentRow({
  agent,
  now,
  onOpenWorkflowAgent,
  variant = "detail",
}: {
  /// The folded workflow agent to render.
  agent: WorkflowAgent;
  /// The shared current time used for running elapsed durations.
  now: number;
  /// Opens the agent's Claude transcript in the existing right pane when available.
  onOpenSubagent?: (id: string) => void;
  /// Opens the workflow transcript through the workflow-specific bridge when available.
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  /// Gallery-only row treatment; detail is the shipped default.
  variant?: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const queued = agent.state === "waiting" || agent.state === "pending";
  const elapsed =
    agent.elapsedMs ??
    (agent.state === "running" && agent.startedAt !== undefined ? Math.max(0, now - agent.startedAt) : undefined);
  const state = agentStateWord(t, agent.state);
  const model = agent.model ? modelName(agent.model) : undefined;
  const modelEffort = [model, agent.effort].filter((value): value is string => Boolean(value)).join(" · ");
  const modelLabel = modelEffort ? t("workflow.model", { model: modelEffort }) : undefined;
  const message = agent.lastMessage ?? agent.doing;
  const time = queued ? undefined : elapsed !== undefined ? formatDuration(elapsed) : undefined;
  const accessibleLabel = [agent.name, modelLabel, message, state, time].filter(Boolean).join(", ");
  // Workflow agent ids name Claude's workflow transcript, not a folded subagent node. Until the
  // workflow bridge is supplied, keep this row inert rather than sending the wrong id to the
  // ordinary subagent opener.
  const className = `acpmux-workflow-agent__button acpmux-workflow-agent__button--${variant}`;
  const content = (
    <>
      <span className="acpmux-workflow-agent__icon" aria-hidden="true">
        {agent.state === "running" ? (
          <Spinner size={ROW_ICON} loading />
        ) : agent.state === "completed" ? (
          <Icon name="status.complete" size={ROW_ICON} row />
        ) : agent.state === "failed" || agent.state === "cancelled" ? (
          <Icon name="status.error" size={ROW_ICON} row />
        ) : (
          <span className="acpmux-workflow-agent__queued-mark" />
        )}
      </span>
      <span className="acpmux-workflow-agent__text">
        <span className="acpmux-workflow-agent__line">
          <span className="acpmux-workflow-agent__name">{agent.name}</span>
          {modelLabel && <span className="acpmux-workflow-agent__model">{modelLabel}</span>}
        </span>
        {message && (
          <span className="acpmux-workflow-agent__doing" title={message}>
            {message}
          </span>
        )}
      </span>
      <span className="acpmux-workflow-agent__state">{state}</span>
      <span className="acpmux-chat-inspector-task__time">{time}</span>
    </>
  );
  return (
    <li className="acpmux-chat-inspector-task acpmux-workflow-agent" data-state={agent.state}>
      {onOpenWorkflowAgent ? (
        <button
          type="button"
          className={className}
          aria-label={accessibleLabel}
          onClick={() => onOpenWorkflowAgent(agent)}
        >
          {content}
        </button>
      ) : (
        <div className={className}>{content}</div>
      )}
    </li>
  );
}

function agentStateWord(t: Translate, state: WorkflowAgent["state"]): string {
  if (state === "running") return t("subagents.state.running");
  if (state === "completed") return t("subagents.state.completed");
  if (state === "failed") return t("subagents.state.failed");
  if (state === "cancelled") return t("subagents.state.cancelled");
  if (state === "waiting" || state === "pending") return t("workflow.agentQueued");
  if (state === "paused") return t("goal.paused");
  return t("inspector.unknown");
}
