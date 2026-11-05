// The chat's Claude workflows in Session Info's Background tasks (Labs, `workflowLabs`): running
// ones first, then the finished ones, each read from the subagent fold (summary/foldWorkflows.ts).
// A workflow shows its name, how long it has run and Stop; a line of its agents' counts, tokens and
// the model they run on; its description; then, as Claude's own Background tasks panel reads (Leo,
// 2026-11-05: "claude does actually do this in a right pane sort of thing ... there are areas to
// improve on around here", and on the list drawn from it: "Definitely just build it."):
// - each phase an agent reached as one row, its count (`1/6`) and a dot per agent, closed until
//   opened, which lists the phase's agents still running or waiting, each saying in words what it
//   does (summary/workflowView.ts `agentLine`), never its last shell command;
// - "Up next: <phase>" for the first phase no agent has reached, never an empty heading;
// - the commands its agents started under the agent that started them (`attributeCommands`);
// - "N finished": the agents that ended, out of the running list, the latest first, each opening
//   to its output drawn as Markdown, never raw JSON (`outputMarkdown`).
// An agent names its model only where it is not the workflow's. A running agent is a spinner, never
// a pulsing dot.
import { Fragment, useId, useLayoutEffect, useRef, useState } from "react";
import { compactTokens } from "../conversation/CompactionNote";
import { Spinner } from "../conversation/icons";
import { Markdown } from "../conversation/Markdown";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import { modelName, phaseAgents, tally, workflowDetailRequest, type Tally } from "../summary/foldWorkflows";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "../summary/workflow";
import {
  agentEnded,
  agentLine,
  agentModelLabel,
  listedPhases,
  listNames,
  outputMarkdown,
  phaseCount,
  splitAgents,
  sharedModel,
  upNext,
  type WorkflowCommands,
} from "../summary/workflowView";
import { commandLabel, sendLabel, type BackgroundCommand } from "./processes";
import { COMMAND_STATE, StopButton } from "./TasksSection";
import { TASK_ICONS } from "./taskIcons";
import "./sessionInfo.css";
import "./WorkflowTasks.css";
import "../summary/workflowDots.css";

const ROW_ICON = rowIconSize(12);

/// How many finished agents a workflow lists before Show more, and how many more each press adds.
const FINISHED_PAGE = 8;

const isRunning = (workflow: WorkflowSummary) => workflow.state === "running";

const NO_COMMANDS: readonly BackgroundCommand[] = [];

export type WorkflowAgentRowVariant = "compact" | "detail" | "grid";

export function WorkflowTasks({
  workflows,
  commands,
  onStop,
  onStopCommand,
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant = "detail",
}: {
  workflows: readonly WorkflowSummary[];
  /// The chat's commands the workflows' agents started (summary/workflowView.ts `attributeCommands`).
  commands?: WorkflowCommands;
  /// Stops a running workflow (its Claude task, `stop_task`); absent where the harness cannot.
  onStop?: (id: string) => Promise<unknown>;
  /// Stops a command (`_acpmux/process/kill`); absent where acpmux cannot.
  onStopCommand?: (id: string) => Promise<unknown>;
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
  // One clock for every row: a running workflow's elapsed time keeps moving even before its first
  // agent event arrives (or while all of its agents are queued), and so does a command one of its
  // agents left running. Nothing running, no timer.
  const commandRuns = [...(commands?.byAgent.values() ?? []), ...(commands?.byWorkflow.values() ?? [])].some((list) =>
    list.some((command) => command.state === "running"),
  );
  const now = useNow(running.length > 0 || commandRuns);
  return (
    <div className="acpmux-workflow-tasks">
      {/* One keyed list preserves phase disclosure and row identity across lifecycle changes. */}
      {[...running, ...finished].map((workflow, index) => (
        <Fragment key={workflow.id}>
          {/* Only mixed groups need headings; the section already counts what runs. */}
          {running.length > 0 && finished.length > 0 && (index === 0 || index === running.length) && (
            <h4 className="acpmux-workflow-tasks__group">
              {index === 0
                ? t("rail.running", { count: running.length })
                : t("rail.finished", { count: finished.length })}
            </h4>
          )}
          <WorkflowTask
            workflow={workflow}
            now={now}
            commands={commands}
            finishedHeadingShown={running.length > 0 && finished.length > 0}
            onStop={isRunning(workflow) ? onStop : undefined}
            onStopCommand={onStopCommand}
            onOpenSubagent={onOpenSubagent}
            onOpenWorkflowAgent={onOpenWorkflowAgent}
            agentRowVariant={agentRowVariant}
          />
        </Fragment>
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
  commands,
  finishedHeadingShown,
  onStop,
  onStopCommand,
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant,
}: {
  workflow: WorkflowSummary;
  now: number;
  commands?: WorkflowCommands;
  finishedHeadingShown: boolean;
  onStop?: (id: string) => Promise<unknown>;
  onStopCommand?: (id: string) => Promise<unknown>;
  onOpenSubagent?: (id: string) => void;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  agentRowVariant: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const running = isRunning(workflow);
  const counts = tally(workflow.agents);
  const shared = sharedModel(workflow.agents);
  const elapsed =
    workflow.elapsedMs ?? (workflow.startedAt !== undefined ? Math.max(0, now - workflow.startedAt) : undefined);
  const tokens = workflow.tokens !== undefined ? [tokensLabel(t, workflow.tokens)] : [];
  // The workflow's model and effort, named once here: an agent row names its own only where it differs.
  const model = shared.model
    ? [[modelName(shared.model), shared.effort].filter((value): value is string => Boolean(value)).join(" · ")]
    : [];
  // Running: what its agents do now. Finished: how it ended and its size.
  const status =
    workflow.state === "completed"
      ? finishedHeadingShown
        ? undefined
        : t("bgTask.state.completed")
      : stateWord(t, workflow.state);
  const meta = running
    ? [...countLine(t, counts), ...tokens, ...model]
    : [...(status ? [status] : []), t("subagents.pill", { n: counts.total }), ...tokens, ...model];
  const phases = listedPhases(workflow);
  const language = usePaneLanguage();
  const next = upNext(workflow)
    .map((phase) => phase.name)
    .filter(Boolean);
  const { finished } = splitAgents(workflow.agents);
  const own = commands?.byWorkflow.get(workflow.id) ?? NO_COMMANDS;
  const agentCommands = (agent: WorkflowAgent) => commands?.byAgent.get(agent.id) ?? NO_COMMANDS;
  return (
    <section className="acpmux-workflow-task" data-state={workflow.state} aria-label={workflow.title}>
      <div className="acpmux-workflow-task__head">
        <span className="acpmux-workflow-task__name">{workflow.title}</span>
        {elapsed !== undefined && <span className="acpmux-session-info-task__time">{formatDuration(elapsed)}</span>}
        {running && onStop && <StopButton id={workflow.id} name={workflow.title} stop={onStop} solid />}
      </div>
      {meta.length > 0 && <p className="acpmux-workflow-task__meta">{meta.join(" · ")}</p>}
      {workflow.description && (
        <p className="acpmux-workflow-task__description" title={workflow.description}>
          {workflow.description}
        </p>
      )}
      {phases.length > 0 && (
        <ul className="acpmux-session-info-list acpmux-workflow-task__phases">
          {phases.map((phase) => (
            <WorkflowPhaseRow
              key={phase.id}
              workflow={workflow}
              phase={phase}
              now={now}
              shared={shared}
              commandsOf={agentCommands}
              onStopCommand={onStopCommand}
              onOpenSubagent={onOpenSubagent}
              onOpenWorkflowAgent={onOpenWorkflowAgent}
              agentRowVariant={agentRowVariant}
            />
          ))}
        </ul>
      )}
      {next.length > 0 && (
        <p className="acpmux-workflow-task__next">{t("workflow.upNext", { phase: listNames(next, language) })}</p>
      )}
      {own.length > 0 && <CommandList commands={own} now={now} onStop={onStopCommand} />}
      {finished.length > 0 && (
        <FinishedAgents
          workflow={workflow}
          agents={finished}
          now={now}
          shared={shared}
          commandsOf={agentCommands}
          onStopCommand={onStopCommand}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
        />
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
  shared,
  commandsOf,
  onStopCommand,
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant,
}: {
  workflow: WorkflowSummary;
  phase: WorkflowPhase;
  now: number;
  shared: { model?: string; effort?: string };
  commandsOf: (agent: WorkflowAgent) => readonly BackgroundCommand[];
  onStopCommand?: (id: string) => Promise<unknown>;
  onOpenSubagent?: (id: string) => void;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  agentRowVariant: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const agents = phaseAgents(workflow, phase);
  // Its agents that ended are under the workflow's "N finished"; the phase opens to the rest.
  const live = agents.filter((agent) => !agentEnded(agent));
  // A phase is one row until opened (Claude's: "Nap 1/6"), unless a command one of its agents started
  // still runs: that one's time and Stop stay in sight. Opened that way it stays open when the command
  // ends, so the rows being read never close under the reader.
  const [chosen, setOpen] = useState<boolean>();
  const commandRuns = live.some((agent) => commandsOf(agent).some((command) => command.state === "running"));
  if (chosen === undefined && commandRuns) setOpen(true);
  const open = chosen ?? commandRuns;
  const { done, total } = phaseCount(workflow, phase);
  const opens = live.length > 0;
  return (
    <li className="acpmux-workflow-phase" data-state={phase.state}>
      {/* A phase with nothing running or waiting has nothing to open: no chevron and no click. */}
      <button
        type="button"
        className="acpmux-workflow-phase__head"
        aria-expanded={opens ? open : undefined}
        disabled={!opens}
        onClick={() => setOpen(!open)}
      >
        <span className="acpmux-workflow-phase__name">{phase.name || t("workflow.unassigned")}</span>
        <span className="acpmux-session-info-task__time">{total > 0 ? `${done}/${total}` : ""}</span>
        {opens && <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />}
      </button>
      {/* A dot per agent says at a glance what the count beside the name says in numbers. */}
      <span className="acpmux-workflow-dots" aria-hidden="true">
        {agents.map((agent) => (
          <span key={agent.id} className="acpmux-workflow-dot" data-state={agent.state} />
        ))}
      </span>
      {open && opens && (
        <ul className="acpmux-session-info-list acpmux-workflow-phase__agents">
          {live.map((agent) => (
            <WorkflowAgentRow
              key={agent.id}
              workflow={workflow}
              agent={agent}
              now={now}
              shared={shared}
              commands={commandsOf(agent)}
              onStopCommand={onStopCommand}
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

/// "N finished": the workflow's agents that ended, the latest first, open (as Claude's Finished
/// reads), each opening to its output. Show more past eight.
function FinishedAgents({
  workflow,
  agents,
  now,
  shared,
  commandsOf,
  onStopCommand,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  agents: readonly WorkflowAgent[];
  now: number;
  shared: { model?: string; effort?: string };
  commandsOf: (agent: WorkflowAgent) => readonly BackgroundCommand[];
  onStopCommand?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(true);
  const [shown, setShown] = useState(FINISHED_PAGE);
  // An agent that ended with a command of its still running stays in sight, its row first and outside
  // the fold and the paging, so that command's time and Stop never hide.
  const busy = agents.filter((agent) => commandsOf(agent).some((command) => command.state === "running"));
  const rest = agents.filter((agent) => !busy.includes(agent));
  const row = (agent: WorkflowAgent) => (
    <WorkflowAgentRow
      key={agent.id}
      workflow={workflow}
      agent={agent}
      now={now}
      shared={shared}
      commands={commandsOf(agent)}
      onStopCommand={onStopCommand}
      onOpenWorkflowAgent={onOpenWorkflowAgent}
    />
  );
  return (
    <div className="acpmux-workflow-finished">
      <button
        type="button"
        className="acpmux-session-info-fold acpmux-workflow-finished__fold"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
        {t("rail.finished", { count: agents.length })}
      </button>
      {(open || busy.length > 0) && (
        <ul className="acpmux-session-info-list acpmux-workflow-finished__agents">
          {busy.map(row)}
          {open && rest.slice(0, shown).map(row)}
        </ul>
      )}
      {open && rest.length > shown && (
        <button
          type="button"
          className="acpmux-session-info-fold acpmux-workflow-finished__more"
          onClick={() => setShown(shown + FINISHED_PAGE * 3)}
        >
          {t("backgroundTasks.showMore")}
        </button>
      )}
    </div>
  );
}

/// A workflow agent's commands: running ones with their time and Stop, ended ones with how long
/// they took and how they ended.
function CommandList({
  commands,
  now,
  onStop,
}: {
  commands: readonly BackgroundCommand[];
  now: number;
  onStop?: (id: string) => Promise<unknown>;
}) {
  const t = useT();
  const ordered = [...commands].sort(
    (a, b) => Number(b.state === "running") - Number(a.state === "running") || (b.startedAt ?? 0) - (a.startedAt ?? 0),
  );
  return (
    <ul className="acpmux-session-info-list acpmux-workflow-commands">
      {ordered.map((command) => {
        const running = command.state === "running";
        const time =
          command.startedAt === undefined
            ? undefined
            : running
              ? formatDuration(Math.max(0, now - command.startedAt))
              : command.endedAt !== undefined
                ? formatDuration(Math.max(0, command.endedAt - command.startedAt))
                : undefined;
        const label = sendLabel(t, command) ?? commandLabel(command);
        return (
          <li
            key={command.toolCallId ?? command.id}
            className="acpmux-session-info-task acpmux-workflow-command"
            data-state={command.state}
            title={command.command}
          >
            <Icon name={TASK_ICONS.command.web} size={ROW_ICON} row className="acpmux-row-glyph" />
            <span className="acpmux-session-info-task__command">{label}</span>
            {time !== undefined && <span className="acpmux-session-info-task__time">{time}</span>}
            {!running && <span className="acpmux-session-info-task__state">{t(COMMAND_STATE[command.state])}</span>}
            {running && command.processId && onStop && (
              <StopButton id={command.processId} name={command.command} stop={onStop} solid />
            )}
          </li>
        );
      })}
    </ul>
  );
}

/// A workflow agent's row: its state, its name, its model where it is not the workflow's, what it
/// does in words, and its elapsed time; under it the commands it started. A finished one has a
/// disclosure that shows its output, rendered. Rows open their transcript through the workflow
/// bridge when one is supplied; without it they remain inert.
export function WorkflowAgentRow({
  workflow,
  agent,
  now,
  shared,
  commands = NO_COMMANDS,
  onStopCommand,
  onOpenWorkflowAgent,
  variant = "detail",
}: {
  /// The parent workflow supplies the session and run that identify this agent's transcript.
  workflow: WorkflowSummary;
  /// The folded workflow agent to render.
  agent: WorkflowAgent;
  /// The shared current time used for running elapsed durations.
  now: number;
  /// The workflow's model and effort, which the row leaves out; read from `workflow` when absent.
  shared?: { model?: string; effort?: string };
  /// The commands this agent started (summary/workflowView.ts `attributeCommands`).
  commands?: readonly BackgroundCommand[];
  onStopCommand?: (id: string) => Promise<unknown>;
  /// Opens the agent's Claude transcript in the existing right pane when available.
  onOpenSubagent?: (id: string) => void;
  /// Opens the workflow transcript through the workflow-specific bridge when available.
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  /// Gallery-only row treatment; detail is the shipped default.
  variant?: WorkflowAgentRowVariant;
}) {
  const t = useT();
  const [outputOpen, setOutputOpen] = useState(false);
  const queued = agent.state === "waiting" || agent.state === "pending";
  // A row that finished well opens to its output (and the commands it started that ended).
  const expandable = agent.state === "completed";
  const elapsed =
    agent.elapsedMs ??
    (agent.state === "running" && agent.startedAt !== undefined ? Math.max(0, now - agent.startedAt) : undefined);
  const state = agentStateWord(t, agent.state);
  // Its model where it is not the workflow's (with its effort), else its effort alone where only that
  // differs.
  const own = agentModelLabel(agent, shared ?? sharedModel(workflow.agents));
  const modelLabel = own?.model
    ? t("workflow.model", {
        model: [modelName(own.model), own.effort].filter((value): value is string => Boolean(value)).join(" · "),
      })
    : own?.effort;
  const message = agentLine(agent);
  const output = agent.state === "completed" ? outputMarkdown(agent) : undefined;
  const time = queued ? undefined : elapsed !== undefined ? formatDuration(elapsed) : undefined;
  const accessibleLabel = [agent.name, modelLabel, message, state, time].filter(Boolean).join(", ");
  // Workflow agent ids name Claude's workflow transcript, not a folded subagent node. Until the
  // workflow bridge is supplied, keep this row inert rather than sending the wrong id to the
  // ordinary subagent opener.
  const openable = Boolean(onOpenWorkflowAgent && workflowDetailRequest(workflow, agent));
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
      <span className="acpmux-session-info-task__time">{time}</span>
    </>
  );
  // Its commands show under it, but for one that finished well the ended ones go with its output.
  // A command still running stays in sight with its Stop, whatever the agent's state.
  const endedCommands = expandable ? commands.filter((command) => command.state !== "running") : NO_COMMANDS;
  const shownCommands = expandable ? commands.filter((command) => command.state === "running") : commands;
  return (
    <li className="acpmux-session-info-task acpmux-workflow-agent" data-state={agent.state}>
      <div className="acpmux-workflow-agent__row">
        {expandable && (
          <button
            type="button"
            className="acpmux-workflow-agent__disclosure"
            aria-expanded={outputOpen}
            aria-label={t("workflow.output", { name: agent.name })}
            title={t("workflow.output", { name: agent.name })}
            onClick={() => setOutputOpen(!outputOpen)}
          >
            <Icon name={outputOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </button>
        )}
        {openable ? (
          <button
            type="button"
            className={className}
            aria-label={accessibleLabel}
            onClick={() => onOpenWorkflowAgent?.(agent)}
          >
            {content}
          </button>
        ) : (
          <div className={className}>{content}</div>
        )}
      </div>
      {expandable && outputOpen && (
        <div className="acpmux-workflow-agent__output">
          {output ? (
            <OutputPreview text={output} />
          ) : agent.state === "completed" ? (
            <p className="acpmux-workflow-agent__no-output">{t("workflow.noOutput")}</p>
          ) : null}
          {endedCommands.length > 0 && <CommandList commands={endedCommands} now={now} onStop={onStopCommand} />}
        </div>
      )}
      {shownCommands.length > 0 && <CommandList commands={shownCommands} now={now} onStop={onStopCommand} />}
    </li>
  );
}

/// A finished agent's output at the row's detail size: its first lines, Show more opening the rest
/// (capped and scrolled). Show more appears only when the cut hides lines (subagents/SubagentDoneLine.tsx
/// `ReportPreview` reads a subagent's report the same way).
function OutputPreview({ text }: { text: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [long, setLong] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight - node.clientHeight > 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    // Stops with the effect: the cleanup disconnects it when the text changes, it opens or unmounts.
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [text, open]);
  return (
    <>
      <div
        ref={ref}
        id={id}
        className="acpmux-workflow-agent__markdown selectable"
        data-cut={open ? undefined : true}
        data-more={long && !open ? true : undefined}
      >
        <Markdown commits="quiet">{text}</Markdown>
      </div>
      {(long || open) && (
        <button
          type="button"
          className="acpmux-workflow-agent__more"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen((value) => !value)}
        >
          {t(open ? "message.less" : "message.more")}
        </button>
      )}
    </>
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
