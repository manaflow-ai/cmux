// The chat's Claude workflows in Session Info's Background tasks (Labs, `workflowLabs`): running
// ones first, then the finished ones, each read from the subagent fold (summary/foldWorkflows.ts).
// A workflow shows its name, how long it has run and Stop; a line of its agents' counts, tokens and
// the model they run on; its description; then, as Claude's own Background tasks panel reads (Leo,
// 2026-11-05: "claude does actually do this in a right pane sort of thing ... there are areas to
// improve on around here", and on the list drawn from it: "Definitely just build it."):
// - each phase as one row, its count (`1/6`) and a dot per agent, closed until opened, which lists
//   the phase's agents still running or waiting, each saying in words what it does
//   (summary/workflowView.ts `agentLine`), never its last shell command. A phase no agent has
//   started is a row like the others, in its pending state, with no label saying it comes next
//   (Leo, 2026-10-29: "I fucking hate it when you guys narrate so much bullshit");
// - the commands its agents started under the agent that started them (`attributeCommands`);
// - "N finished": the agents that ended, out of the running list, the latest first, each opening
//   to its output drawn as Markdown, never raw JSON (`outputMarkdown`).
// An agent names its model only where it is not the workflow's. A running agent is a spinner, never
// a pulsing dot.
import { Fragment, memo, useCallback, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { compactTokens } from "../conversation/compactionNoteModel";
import { Spinner } from "../conversation/icons";
import { CountLine, type CountPart } from "../summary/LiveCount";
import { Markdown } from "../conversation/Markdown";
import { formatDuration, spanDuration } from "../conversation/turns";
import { useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/subagentGroupModel";
import { modelName, phaseAgents, tally, workflowDetailRequest, type Tally } from "../summary/foldWorkflows";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "../summary/workflow";
import {
  agentEnded,
  agentLine,
  agentModelLabel,
  outputMarkdown,
  phaseCount,
  splitAgents,
  sharedModel,
  type WorkflowCommands,
} from "../summary/workflowView";
import { commandLabel, sendLabel, type BackgroundCommand } from "./processes";
import { CommandTime, StopButton } from "./TasksSection";
import { COMMAND_STATE } from "./tasksSectionModel";
import { TASK_ICONS } from "./taskIcons";
import "./sessionInfo.css";
import "./WorkflowTasks.css";
import "../summary/workflowDots.css";
import { WindowedRows } from "./WindowedRows";
import { orderedCountParts } from "./subagentsSectionModel";
import { StateMark } from "../summary/StateMark";
import { Clock } from "../../../ui/Typography";
import { sameValue } from "./sameValue";

const ROW_ICON = rowIconSize(12);

type Same<T> = (a: T, b: T) => boolean;

// Every snapshot acpmux sends is new objects, and a workflow's progress bumps `progressVersion` on
// every one of its agents: rows memoized by reference, or on every field, drew again each time though
// nothing they show changed. The rows compare what they draw instead, by these tables over every
// field of an agent and of a workflow: a new field fails to compile here until it is classed as
// drawn (compared) or not (null).

/// A workflow agent's fields, as its row (WorkflowAgentLine) and its phase's dots and count read them.
const AGENT_LOOK: { [K in keyof WorkflowAgent]-?: Same<WorkflowAgent[K]> | null } = {
  id: Object.is,
  name: Object.is,
  state: Object.is,
  // Its open's (summary/foldWorkflows.ts `workflowDetailRequest`).
  agentId: Object.is,
  doing: Object.is,
  lastMessage: Object.is,
  prompt: Object.is,
  result: Object.is,
  error: Object.is,
  model: Object.is,
  effort: Object.is,
  elapsedMs: Object.is,
  startedAt: Object.is,
  // The workflow's progress sequence (every agent of it gets the same one) and when it last did
  // anything: the fold's and the card's latest line (workflowView.ts `cardLine`), no row's.
  progressVersion: null,
  lastProgressAt: null,
  // Its place among the finished ones (workflowView.ts `splitAgents`): the list's order, not the row.
  index: null,
  // Its tokens and whether they came from a cache: the workflow's total says them, no agent row.
  tokens: null,
  cached: null,
  retryReason: null,
  transcriptRowId: null,
};
const AGENT_FIELDS = Object.entries(AGENT_LOOK).filter(
  (entry): entry is [keyof WorkflowAgent, Same<unknown>] => entry[1] !== null,
);
const sameAgentLook = (a: WorkflowAgent, b: WorkflowAgent) =>
  a === b || AGENT_FIELDS.every(([key, same]) => same(a[key], b[key]));

/// A workflow's fields, as a phase's row (WorkflowPhaseRow) reads them: only what opens its agents;
/// its agents are compared by AGENT_LOOK, the phase's own (`samePhaseProps`).
const PHASE_WORKFLOW_LOOK: { [K in keyof WorkflowSummary]-?: Same<WorkflowSummary[K]> | null } = {
  sessionId: Object.is,
  runId: Object.is,
  agents: null,
  // The workflow's head draws these (WorkflowTask), not its phases.
  id: null,
  title: null,
  description: null,
  state: null,
  resumedFrom: null,
  counts: null,
  projectedTokens: null,
  action: null,
  phase: null,
  phases: null,
  elapsedMs: null,
  startedAt: null,
  tokens: null,
  large: null,
  selectedAgentId: null,
};
const PHASE_WORKFLOW_FIELDS = Object.entries(PHASE_WORKFLOW_LOOK).filter(
  (entry): entry is [keyof WorkflowSummary, Same<unknown>] => entry[1] !== null,
);

/// How many finished agents a workflow lists before Show more (each press adds three times as many).
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
  // No clock here: each time that moves (a running workflow's, its agents', the commands they left
  // running) ticks in a leaf of its own, so a second's tick splits, counts and draws none of this.
  const running = workflows.filter(isRunning);
  const finished = workflows.filter((workflow) => !isRunning(workflow));
  return (
    <div className="acpmux-workflow-tasks">
      {/* One keyed list preserves phase disclosure and row identity across lifecycle changes. */}
      {[...running, ...finished].map((workflow, index) => (
        <Fragment key={workflow.id}>
          {/* Only mixed groups need a heading, and only the finished one: the running ones lead the
              list and need no word (Leo, 2026-11-23: ""running" doesn't need text. it can usually just
              be."); the section already counts what runs. */}
          {running.length > 0 && finished.length > 0 && index === running.length && (
            <h4 className="acpmux-workflow-tasks__group">{t("rail.finished", { count: finished.length })}</h4>
          )}
          <WorkflowTask
            workflow={workflow}
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

/// "1 failed · (mark) 1 · 2 queued · 3 done": each count that is not zero, in the shared order, the
/// running ones as their mark and number (LiveCount.tsx).
function countLine(t: Translate, counts: Tally): CountPart[] {
  return orderedCountParts(
    { failed: counts.failed, running: counts.running, queued: counts.queued, done: counts.done },
    t,
  );
}

const tokensLabel = (t: Translate, tokens: number) =>
  t("subagents.tokens", { n: tokens, tokens: compactTokens(tokens) });

function WorkflowTask({
  workflow,
  commands,
  finishedHeadingShown,
  onStop,
  onStopCommand,
  onOpenSubagent,
  onOpenWorkflowAgent,
  agentRowVariant,
}: {
  workflow: WorkflowSummary;
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
  // Stable while the workflow's agents are: the rows under it take them as props.
  const shared = useMemo(() => sharedModel(workflow.agents), [workflow.agents]);
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
  const meta: CountPart[] = running
    ? [...countLine(t, counts), ...tokens, ...model]
    : [...(status ? [status] : []), t("subagents.pill", { n: counts.total }), ...tokens, ...model];
  const phases = workflow.phases;
  const { finished } = splitAgents(workflow.agents);
  const own = commands?.byWorkflow.get(workflow.id) ?? NO_COMMANDS;
  const agentCommands = useCallback(
    (agent: WorkflowAgent) => commands?.byAgent.get(agent.id) ?? NO_COMMANDS,
    [commands],
  );
  return (
    <section className="acpmux-workflow-task" data-state={workflow.state} aria-label={workflow.title}>
      <div className="acpmux-workflow-task__head">
        <span className="acpmux-workflow-task__name">{workflow.title}</span>
        {(workflow.elapsedMs !== undefined || workflow.startedAt !== undefined) && (
          <span className="acpmux-session-info-task__time">
            <ElapsedTime elapsedMs={workflow.elapsedMs} since={workflow.startedAt} ticks={running} />
          </span>
        )}
        {running && onStop && <StopButton id={workflow.id} name={workflow.title} stop={onStop} solid />}
      </div>
      {meta.length > 0 && (
        <p className="acpmux-workflow-task__meta">
          <CountLine parts={meta} />
        </p>
      )}
      {workflow.description && <p className="acpmux-workflow-task__description">{workflow.description}</p>}
      {phases.length > 0 && (
        <ul className="acpmux-session-info-list acpmux-workflow-task__phases">
          {phases.map((phase) => (
            <WorkflowPhaseRow
              key={phase.id}
              workflow={workflow}
              phase={phase}
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
      {own.length > 0 && <CommandList commands={own} onStop={onStopCommand} />}
      {finished.length > 0 && (
        <FinishedAgents
          workflow={workflow}
          agents={finished}
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

type PhaseRowProps = {
  workflow: WorkflowSummary;
  phase: WorkflowPhase;
  shared: { model?: string; effort?: string };
  commandsOf: (agent: WorkflowAgent) => readonly BackgroundCommand[];
  onStopCommand?: (id: string) => Promise<unknown>;
  onOpenSubagent?: (id: string) => void;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  agentRowVariant: WorkflowAgentRowVariant;
};

/// A phase's row, its own memo boundary: the clock never draws it (its agents' rows keep their own
/// time), and a change to another workflow, to an agent of another phase, or a snapshot that only
/// brings new objects leaves it alone (`samePhaseProps`).
const WorkflowPhaseRow = memo(function WorkflowPhaseRow({
  workflow,
  phase,
  shared,
  commandsOf,
  onStopCommand,
  onOpenWorkflowAgent,
  agentRowVariant,
}: PhaseRowProps) {
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
          <WindowedRows
            items={live}
            render={(agent) => (
              <WorkflowAgentLine
                key={agent.id}
                agent={agent}
                shared={shared}
                openable={Boolean(onOpenWorkflowAgent && workflowDetailRequest(workflow, agent))}
                commands={commandsOf(agent)}
                onStopCommand={onStopCommand}
                onOpenWorkflowAgent={onOpenWorkflowAgent}
                variant={agentRowVariant}
              />
            )}
          />
        </ul>
      )}
    </li>
  );
}, samePhaseProps);

/// Whether a phase's row draws the same: its phase, the workflow's fields it reads, its agents and
/// the commands they started by what they draw, and the rest of its props by identity.
function samePhaseProps(a: PhaseRowProps, b: PhaseRowProps): boolean {
  if (
    a.onStopCommand !== b.onStopCommand ||
    a.onOpenSubagent !== b.onOpenSubagent ||
    a.onOpenWorkflowAgent !== b.onOpenWorkflowAgent ||
    a.agentRowVariant !== b.agentRowVariant ||
    !sameValue(a.phase, b.phase) ||
    !sameValue(a.shared, b.shared) ||
    !PHASE_WORKFLOW_FIELDS.every(([key, same]) => same(a.workflow[key], b.workflow[key]))
  )
    return false;
  const was = phaseAgents(a.workflow, a.phase);
  const is = phaseAgents(b.workflow, b.phase);
  return (
    was.length === is.length &&
    was.every(
      (agent, index) =>
        sameAgentLook(agent, is[index]!) &&
        (a.commandsOf === b.commandsOf || sameValue(a.commandsOf(agent), b.commandsOf(is[index]!))),
    )
  );
}

/// "N finished": the workflow's agents that ended, the latest first, open (as Claude's Finished
/// reads), each opening to its output. Show more past eight.
function FinishedAgents({
  workflow,
  agents,
  shared,
  commandsOf,
  onStopCommand,
  onOpenWorkflowAgent,
}: {
  workflow: WorkflowSummary;
  agents: readonly WorkflowAgent[];
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
  const busyIds = new Set(busy.map((agent) => agent.id));
  const rest = agents.filter((agent) => !busyIds.has(agent.id));
  const row = (agent: WorkflowAgent) => (
    <WorkflowAgentLine
      key={agent.id}
      agent={agent}
      shared={shared}
      openable={Boolean(onOpenWorkflowAgent && workflowDetailRequest(workflow, agent))}
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
  /// A fixed time (a gallery, a test); without it a running command's time keeps its own clock
  /// (TasksSection.tsx `CommandTime`), which draws that time and not the list.
  now?: number;
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
          command.startedAt === undefined || running
            ? undefined
            : command.endedAt !== undefined
              ? spanDuration(t, command.endedAt - command.startedAt)
              : undefined;
        const label = sendLabel(t, command) ?? commandLabel(command);
        return (
          <li
            key={command.toolCallId ?? command.id}
            className="acpmux-session-info-task acpmux-workflow-command"
            data-state={command.state}
          >
            <Icon name={TASK_ICONS.command.web} size={ROW_ICON} row fit className="acpmux-row-glyph" />
            <span className="acpmux-session-info-task__command">{label}</span>
            {running && command.startedAt !== undefined && <CommandTime since={command.startedAt} now={now} />}
            {time !== undefined && <Clock className="acpmux-session-info-task__time" text={time} />}
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
  /// The shared current time used for running elapsed durations; without it the row keeps its own.
  now?: number;
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
  // Workflow agent ids name Claude's workflow transcript, not a folded subagent node. Until the
  // workflow bridge is supplied, keep this row inert rather than sending the wrong id to the
  // ordinary subagent opener.
  return (
    <WorkflowAgentLine
      agent={agent}
      now={now}
      shared={shared ?? sharedModel(workflow.agents)}
      openable={Boolean(onOpenWorkflowAgent && workflowDetailRequest(workflow, agent))}
      commands={commands}
      onStopCommand={onStopCommand}
      onOpenWorkflowAgent={onOpenWorkflowAgent}
      variant={variant}
    />
  );
}

type AgentLineProps = {
  agent: WorkflowAgent;
  now?: number;
  shared: { model?: string; effort?: string };
  /// The workflow bridge can open this agent's transcript.
  openable: boolean;
  commands?: readonly BackgroundCommand[];
  onStopCommand?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  variant?: WorkflowAgentRowVariant;
};

/// The row itself, its own memo boundary with the values it draws (`sameAgentLineProps`): a change to
/// another agent of the workflow, a snapshot that only brings new objects or bumps the workflow's
/// progress sequence, or the clock, draws it again not at all. A running one's time is a leaf with
/// its own clock (ElapsedTime; `now` pins it), and the row's accessible name takes that time from
/// the leaf (aria-labelledby), so a tick draws the time alone.
const WorkflowAgentLine = memo(function WorkflowAgentLine({
  agent,
  now: given,
  shared,
  openable,
  commands = NO_COMMANDS,
  onStopCommand,
  onOpenWorkflowAgent,
  variant = "detail",
}: AgentLineProps) {
  const t = useT();
  const id = useId();
  const [outputOpen, setOutputOpen] = useState(false);
  const queued = agent.state === "waiting" || agent.state === "pending";
  // A row that finished well opens to its output (and the commands it started that ended).
  const expandable = agent.state === "completed";
  // Its time: how long it took, or how long it has run while it runs; none while queued.
  const timed =
    !queued && (agent.elapsedMs !== undefined || (agent.state === "running" && agent.startedAt !== undefined));
  const state = agentStateWord(t, agent.state);
  // Its model where it is not the workflow's (with its effort), else its effort alone where only that
  // differs.
  const modelOwn = agentModelLabel(agent, shared);
  const modelLabel = modelOwn?.model
    ? t("workflow.model", {
        model: [modelName(modelOwn.model), modelOwn.effort]
          .filter((value): value is string => Boolean(value))
          .join(" · "),
      })
    : modelOwn?.effort;
  const message = agentLine(agent);
  const output = agent.state === "completed" ? outputMarkdown(agent) : undefined;
  // What a screen reader hears, as one name: "punchy, Model: Sonnet 5.5 · high, Done, 7s". The words
  // before the time are the row's; the time is the leaf's own text (aria-labelledby joins the two
  // with a space, so the row says "…, Done," and the leaf "7s").
  const labelId = `${id}-label`;
  const timeId = `${id}-time`;
  const accessibleLabel = [agent.name, modelLabel, message, state].filter(Boolean).join(", ");
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
        {message && <span className="acpmux-workflow-agent__doing">{message}</span>}
      </span>
      <StateMark className="acpmux-workflow-agent__state" state={agent.state} label={state} />
      <span className="acpmux-session-info-task__time" id={timeId}>
        {timed && (
          <ElapsedTime
            elapsedMs={agent.elapsedMs}
            since={agent.startedAt}
            ticks={agent.state === "running"}
            now={given}
          />
        )}
      </span>
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
            aria-labelledby={timed ? `${labelId} ${timeId}` : labelId}
            onClick={() => onOpenWorkflowAgent?.(agent)}
          >
            {content}
            {/* The name's words before the time: never shown, found or copied, only read as the name. */}
            <span id={labelId} hidden>
              {timed ? `${accessibleLabel},` : accessibleLabel}
            </span>
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
          {endedCommands.length > 0 && <CommandList commands={endedCommands} now={given} onStop={onStopCommand} />}
        </div>
      )}
      {shownCommands.length > 0 && <CommandList commands={shownCommands} now={given} onStop={onStopCommand} />}
    </li>
  );
}, sameAgentLineProps);

/// Whether an agent's row draws the same: its agent by AGENT_LOOK, the rest by value.
function sameAgentLineProps(a: AgentLineProps, b: AgentLineProps): boolean {
  for (const key in a) {
    if (key === "agent") continue;
    if (!sameValue(a[key as keyof AgentLineProps], b[key as keyof AgentLineProps])) return false;
  }
  for (const key in b) if (!(key in a)) return false;
  return sameAgentLook(a.agent, b.agent);
}

/// How long a workflow or one of its agents took (`elapsedMs`), or has run since `since` while it
/// `ticks`: the one part of its row the second's clock draws, a leaf of its own. `now` pins the time
/// (a gallery, a test). Its text is the row's time and the end of the row's accessible name.
function ElapsedTime({
  elapsedMs,
  since,
  ticks,
  now: fixed,
}: {
  elapsedMs?: number;
  since?: number;
  ticks: boolean;
  now?: number;
}) {
  const own = useNow(fixed === undefined && ticks && elapsedMs === undefined && since !== undefined);
  const elapsed = elapsedMs ?? (since !== undefined ? Math.max(0, (fixed ?? own) - since) : undefined);
  return elapsed !== undefined ? formatDuration(elapsed) : null;
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
