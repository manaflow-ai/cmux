// Session Info's Background tasks as the App draws it (model.ts): what Session Info's `tasks`,
// WorkflowTasks.tsx, ServersSection.tsx and TasksSection.tsx show, as plain rows. The chat's Claude
// workflows first (running, then finished; each with its phases and, in an open phase, its agents),
// then the dev servers, then the running commands and the wakeups and cron jobs still ahead, then
// "N finished", which opens into the ended commands and the scheduled items whose time has passed
// (session-info/scheduled.ts), latest first. The lists, their order and their words come from the page's
// own helpers, so both panels say the same thing.
import { useState } from "react";
import { formatDuration } from "../../conversation/turns";
import type { StringKey, Translate } from "../../i18n";
import { openCommand } from "../../processTerminal";
import { modelName, phaseAgents, phaseState, tally, workflowDetailRequest } from "../../summary/foldWorkflows";
import type { SummaryBackgroundTask, SummaryWakeup } from "../../summary/sessionSummary";
import type { WorkflowAgent, WorkflowSummary } from "../../summary/workflow";
import {
  arrivalKey,
  sessionInfoLists,
  sendLabel,
  splitCommands,
  type BackgroundCommand,
  type SessionInfoProcess,
} from "../processes";
import { COMMAND_STATE } from "../TasksSection";
import { scheduledTrailing, splitScheduled, type ScheduledEntry } from "../scheduled";
import { TASK_ICONS } from "../taskIcons";
import { compactTokens } from "../../conversation/CompactionNote";
import type { NativeInfoActions, NativeInfoButton, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";
import { nativeExternalUrl } from "./links";

export type TasksSectionInput = {
  /// The section is unfolded (Session Info's `state.tasks`).
  open: boolean;
  /// The registry's processes, the transcript's background tasks and whether the registry listed the
  /// chat: split into servers and commands as Session Info does (`sessionInfoLists`).
  processes: readonly SessionInfoProcess[];
  transcriptTasks: readonly SummaryBackgroundTask[];
  listed: boolean;
  /// The wakeups and cron jobs the agent scheduled (sessionSummary `scheduled`).
  scheduled: readonly SummaryWakeup[];
  /// The chat's Claude workflows (Labs).
  workflows: readonly WorkflowSummary[];
  /// The chat runs on this Mac (processTerminal.ts `opensProcessTerminal`): a command's terminal opens.
  local: boolean;
  /// The tool calls the loaded transcript holds (Session Info's `calls`): a row whose call is among
  /// them can show it.
  calls?: ReadonlySet<string>;
  onShowCall?: (toolCallId: string) => boolean;
  onStopProcess?: (id: string) => Promise<unknown>;
  onStopWorkflow?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  onOpenUrl?: (url: string) => void;
  /// The clock the elapsed times read (the page's `useNow`, and `useScheduledClock` for when a
  /// wakeup or cron job ends).
  now: number;
  /// The pane's language, for a cron schedule's words and a wakeup's time of day.
  language?: string;
  /// The finished commands show under "N finished"; `onFinishedOpen` flips it.
  finishedOpen?: boolean;
  onFinishedOpen?: (open: boolean) => void;
  /// The page-owned phase choices, by `<workflow id>/<phase id>` (useNativeWorkflowPhases).
  phases?: Readonly<Record<string, boolean>>;
  onPhase?: (key: string, open: boolean) => void;
  /// Optimistic status for stop operations; parent clears on process/workflow snapshots.
  operations?: Readonly<Record<string, "pending" | "failed">>;
};

const COMMAND_TONE: Record<BackgroundCommand["state"], NativeInfoTone> = {
  running: "running",
  completed: "done",
  failed: "failed",
  stopped: "muted",
  lost: "muted",
};

const SCHEDULED_TONE: Record<ScheduledEntry["status"]["state"], NativeInfoTone> = {
  scheduled: "waiting",
  done: "done",
  expired: "muted",
  cancelled: "muted",
  failed: "failed",
};

const WORKFLOW_TONE: Record<WorkflowAgent["state"], NativeInfoTone> = {
  running: "running",
  paused: "waiting",
  waiting: "waiting",
  pending: "waiting",
  completed: "done",
  failed: "failed",
  cancelled: "muted",
  unknown: "muted",
};

/// Session Info's Background tasks, or undefined when the chat has no workflow, server, command or
/// scheduled task (Session Info's condition).
export function tasksSection(
  input: TasksSectionInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { servers, tasks: commands } = sessionInfoLists(input.processes, input.transcriptTasks, input.listed);
  const { workflows, scheduled, now } = input;
  if (servers.length + commands.length + scheduled.length + workflows.length === 0) return undefined;
  const stop = (id: string, name: string, run: (id: string) => Promise<unknown>, key: string): NativeInfoButton => {
    const operationKey = key.startsWith("tasks.stopWorkflow:") ? `workflow:${id}` : `process:${id}`;
    const state = input.operations?.[operationKey];
    return {
      label: t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", { name }),
      symbol: "stop.fill",
      action: actions.add(key, () => run(id)),
      ...(state === "pending" ? { disabled: true } : {}),
    };
  };
  const rows: NativeInfoRow[] = [...workflowRows(input, actions, t, stop)];
  const openUrl = nativeExternalUrl(input.onOpenUrl);

  // Servers, newest first: the command, the ports it names (each explicit port is its own button)
  // and how long it has run. The row itself stays plain, like ServersSection.tsx.
  for (const server of [...servers].sort((a, b) => b.startedAt - a.startedAt)) {
    const urls = server.ports.map((port) => `http://localhost:${port}`);
    const buttons: NativeInfoButton[] = [];
    if (urls.length > 0)
      for (const url of urls)
        buttons.push({
          label: t("sessionInfo.servers.open", { url }),
          symbol: "link",
          action: actions.add(`tasks.openUrl:${server.id}:${url}`, () => openUrl(url)),
        });
    if (input.onStopProcess)
      buttons.push(stop(server.id, server.command, input.onStopProcess, `tasks.stop:${server.id}`));
    rows.push({
      id: `server:${server.id}`,
      symbol: "server.rack",
      title: server.command,
      detail: formatDuration(Math.max(0, now - server.startedAt)),
      ...(server.ports.length > 0 ? { trailing: server.ports.map((port) => `:${port}`).join(" ") } : {}),
      tone: "running",
      ...(buttons.length > 0 ? { buttons } : {}),
    });
  }

  const { running, finished } = splitCommands(commands);
  const command = (item: BackgroundCommand, trailing: string | undefined): NativeInfoRow => {
    const key = arrivalKey(item);
    const why: StringKey | undefined = !item.toolCallId
      ? "sessionInfo.tasks.noTerminal.noCall"
      : input.local || (input.calls?.has(item.toolCallId) ?? false)
        ? undefined
        : "sessionInfo.tasks.noTerminal.remote";
    const onStop = input.onStopProcess;
    return {
      id: `command:${key}`,
      symbol: TASK_ICONS.command.native,
      title: sendLabel(t, item) ?? item.command,
      ...(trailing ? { trailing } : {}),
      tone: COMMAND_TONE[item.state],
      ...(why === undefined
        ? {
            action: actions.add(`tasks.open:${key}`, () =>
              openCommand(item.toolCallId, { local: input.local, showCall: input.onShowCall }),
            ),
          }
        : {}),
      help: why ? t(why) : item.command,
      ...(item.state === "running" && item.processId && onStop
        ? { buttons: [stop(item.processId, item.command, onStop, `tasks.stop:${item.processId}`)] }
        : {}),
    };
  };
  for (const item of running)
    rows.push(
      command(
        item,
        // A task only the transcript knows may not say when it started.
        item.startedAt !== undefined ? formatDuration(Math.max(0, now - item.startedAt)) : t(COMMAND_STATE.running),
      ),
    );
  const { active, finished: ended } = splitScheduled(scheduled, now);
  const scheduledRow = (entry: ScheduledEntry): NativeInfoRow => {
    const trailing = scheduledTrailing(t, input.language ?? "en", entry);
    const ended = entry.status.state !== "scheduled";
    return {
      id: `scheduled:${entry.item.id}`,
      symbol: TASK_ICONS[entry.item.kind].native,
      title: entry.item.text,
      ...(trailing ? { trailing } : {}),
      ...(ended ? { tone: SCHEDULED_TONE[entry.status.state] } : {}),
      help: entry.item.cron && !ended ? `${entry.item.text} (${entry.item.cron})` : entry.item.text,
    };
  };
  for (const entry of active) rows.push(scheduledRow(entry));
  const finishedCommand = (item: BackgroundCommand): NativeInfoRow => {
    const time =
      item.endedAt !== undefined && item.startedAt !== undefined
        ? formatDuration(Math.max(0, item.endedAt - item.startedAt))
        : undefined;
    return command(item, [time, t(COMMAND_STATE[item.state])].filter(Boolean).join(" · "));
  };
  // The ended commands and scheduled items as one list, latest first.
  const finishedRows = [
    ...finished.map((item) => ({ at: item.endedAt ?? item.startedAt, row: () => finishedCommand(item) })),
    ...ended.map((entry) => ({ at: entry.status.endedAt, row: () => scheduledRow(entry) })),
  ].sort((a, b) => (b.at ?? -Infinity) - (a.at ?? -Infinity));
  if (finishedRows.length > 0) {
    const finishedOpen = input.finishedOpen ?? false;
    const onFinishedOpen = input.onFinishedOpen;
    rows.push({
      id: "finished",
      symbol: finishedOpen ? "chevron.down" : "chevron.right",
      title: t("rail.finished", { count: finishedRows.length }),
      tone: "muted",
      ...(onFinishedOpen ? { action: actions.add("tasks.finished", () => onFinishedOpen(!finishedOpen)) } : {}),
    });
    if (finishedOpen) for (const entry of finishedRows) rows.push(entry.row());
  }

  const runningCount =
    running.length + servers.length + workflows.filter((workflow) => workflow.state === "running").length;
  return {
    id: "tasks",
    group: "running",
    title: t("summary.backgroundTasks"),
    ...(runningCount > 0 ? { meta: t("rail.running", { count: runningCount }), metaTone: "running" as const } : {}),
    open: input.open,
    foldable: true,
    rows,
  };
}

type PhaseChoice = { started: boolean; open: boolean };
export type NativeWorkflowPhaseChoices = Readonly<Record<string, PhaseChoice>>;

/// The same mounted-phase lifetime as WorkflowPhaseRow: pending rows start closed, and the first
/// agent starting opens a running phase. Later agent/count changes keep the person's fold choice.
export function reconcileNativeWorkflowPhases(
  workflows: readonly WorkflowSummary[],
  previous: NativeWorkflowPhaseChoices,
): NativeWorkflowPhaseChoices {
  const next: Record<string, PhaseChoice> = {};
  let changed = false;
  for (const workflow of workflows) {
    for (const phase of workflow.phases) {
      const key = `${workflow.id}/${phase.id}`;
      const agents = phaseAgents(workflow, phase);
      const started = phaseState(agents) !== "pending";
      const was = previous[key];
      const opens = workflow.state === "running" && tally(agents).running > 0;
      next[key] = !was
        ? { started, open: opens }
        : was.started !== started
          ? { started, open: started ? opens : was.open }
          : was;
      if (next[key] !== was) changed = true;
    }
  }
  return changed || Object.keys(next).length !== Object.keys(previous).length ? next : previous;
}

/// Keep folds in the page; Swift only sends the phase's action id back. Pass no workflows when the
/// section body unmounts, matching the web section's phase children being removed.
export function useNativeWorkflowPhases(workflows: readonly WorkflowSummary[]) {
  const [choices, setChoices] = useState<NativeWorkflowPhaseChoices>({});
  const next = reconcileNativeWorkflowPhases(workflows, choices);
  if (next !== choices) setChoices(next);
  return {
    phases: Object.fromEntries(Object.entries(next).map(([key, choice]) => [key, choice.open])),
    onPhase: (key: string, open: boolean) =>
      setChoices((current) => {
        const choice = current[key];
        return choice && choice.open !== open ? { ...current, [key]: { ...choice, open } } : current;
      }),
  };
}

const workflowCounts = (t: Translate, agents: readonly WorkflowAgent[]) => {
  const counts = tally(agents);
  return [
    counts.running > 0 && t("summary.subagents.running", { n: counts.running }),
    counts.queued > 0 && t("workflow.queued", { n: counts.queued }),
    counts.done > 0 && t("summary.subagents.done", { n: counts.done }),
    counts.failed > 0 && t("summary.subagents.failed", { n: counts.failed }),
  ].filter((part): part is string => typeof part === "string");
};

const workflowStateWord = (t: Translate, state: WorkflowAgent["state"]): string => {
  if (state === "running") return t("subagents.state.running");
  if (state === "completed") return t("subagents.state.completed");
  if (state === "failed") return t("subagents.state.failed");
  if (state === "cancelled") return t("subagents.state.cancelled");
  if (state === "waiting" || state === "pending") return t("workflow.agentQueued");
  if (state === "paused") return t("goal.paused");
  return t("inspector.unknown");
};

const workflowAgentSymbol = (state: WorkflowAgent["state"]) =>
  state === "completed" ? "checkmark" : state === "failed" || state === "cancelled" ? "xmark" : "circle";

const phaseMark = (state: WorkflowAgent["state"]): NativeInfoTone =>
  state === "running" || state === "paused"
    ? "accent"
    : state === "completed"
      ? "done"
      : state === "failed" || state === "cancelled"
        ? "failed"
        : "muted";

/// WorkflowTasks' rows: running and finished groups, visible descriptions, every phase in source
/// order (including pending ones), and an open phase's agents. Empty phases have nothing to open.
function workflowRows(
  input: TasksSectionInput,
  actions: NativeInfoActions,
  t: Translate,
  stop: (id: string, name: string, run: (id: string) => Promise<unknown>, key: string) => NativeInfoButton,
): NativeInfoRow[] {
  const rows: NativeInfoRow[] = [];
  const isRunning = (workflow: WorkflowSummary) => workflow.state === "running";
  const running = input.workflows.filter(isRunning);
  const finished = input.workflows.filter((workflow) => !isRunning(workflow));
  const both = running.length > 0 && finished.length > 0;
  const workflow = (item: WorkflowSummary) => {
    const live = isRunning(item);
    const elapsed =
      item.elapsedMs ?? (item.startedAt !== undefined ? Math.max(0, input.now - item.startedAt) : undefined);
    const counts = tally(item.agents);
    const tokens =
      item.tokens !== undefined ? [t("subagents.tokens", { n: item.tokens, tokens: compactTokens(item.tokens) })] : [];
    const status =
      item.state === "completed" ? (both ? undefined : t("bgTask.state.completed")) : workflowStateWord(t, item.state);
    const meta = live
      ? [...workflowCounts(t, item.agents), ...tokens]
      : [...(status ? [status] : []), t("subagents.pill", { n: counts.total }), ...tokens];
    const onStop = input.onStopWorkflow;
    rows.push({
      id: `workflow:${item.id}`,
      symbol: "point.3.connected.trianglepath.dotted",
      title: item.title,
      ...(meta.length > 0 ? { subtitle: meta.join(" · ") } : {}),
      ...(elapsed !== undefined ? { trailing: formatDuration(elapsed) } : {}),
      tone: WORKFLOW_TONE[item.state],
      ...(live && onStop ? { buttons: [stop(item.id, item.title, onStop, `tasks.stopWorkflow:${item.id}`)] } : {}),
    });
    if (item.description)
      rows.push({
        id: `workflowDescription:${item.id}`,
        title: item.description,
        help: item.description,
        tone: "muted",
        indent: 1,
      });
    for (const phase of item.phases) {
      const agents = phaseAgents(item, phase);
      const counts = tally(agents);
      const key = `${item.id}/${phase.id}`;
      const open = input.phases?.[key] ?? (live && counts.running > 0);
      const onPhase = input.onPhase;
      const label = live
        ? workflowCounts(t, agents).join(" · ")
        : counts.total > 0
          ? `${counts.done}/${counts.total}`
          : "";
      rows.push({
        id: `phase:${key}`,
        ...(agents.length > 0 ? { symbol: open ? "chevron.down" : "chevron.right" } : {}),
        title: phase.name || t("workflow.unassigned"),
        ...(label ? { trailing: label } : {}),
        marks: agents.map((agent) => phaseMark(agent.state)),
        indent: 1,
        ...(agents.length > 0 && onPhase
          ? { action: actions.add(`tasks.phase:${key}`, () => onPhase(key, !open)) }
          : {}),
      });
      if (!open) continue;
      for (const agent of agents) {
        const modelEffort = [agent.model ? modelName(agent.model) : undefined, agent.effort]
          .filter((value): value is string => Boolean(value))
          .join(" · ");
        const model = modelEffort ? t("workflow.model", { model: modelEffort }) : undefined;
        const message = (agent.state === "failed" ? agent.error : undefined) ?? agent.lastMessage ?? agent.doing;
        const elapsed =
          agent.elapsedMs ??
          (agent.state === "running" && agent.startedAt !== undefined
            ? Math.max(0, input.now - agent.startedAt)
            : undefined);
        const onOpen = input.onOpenWorkflowAgent;
        const openable = Boolean(onOpen && workflowDetailRequest(item, agent));
        const time =
          agent.state === "waiting" || agent.state === "pending" || elapsed === undefined
            ? undefined
            : formatDuration(elapsed);
        const state = workflowStateWord(t, agent.state);
        rows.push({
          id: `workflowAgent:${item.id}/${agent.id}`,
          symbol: workflowAgentSymbol(agent.state),
          title: agent.name,
          ...(model ? { detail: model } : {}),
          ...(message ? { subtitle: message } : {}),
          trailing: [state, time].filter(Boolean).join(" · "),
          help: [agent.name, model, message, state, time].filter(Boolean).join(", "),
          tone: WORKFLOW_TONE[agent.state],
          indent: 2,
          ...(openable
            ? {
                action: actions.add(`tasks.openWorkflowAgent:${item.id}/${agent.id}`, () => onOpen!(agent)),
              }
            : {}),
        });
      }
    }
  };
  if (both)
    rows.push({
      id: "workflows.running",
      title: t("rail.running", { count: running.length }),
      tone: "muted",
    });
  running.forEach(workflow);
  if (both)
    rows.push({
      id: "workflows.finished",
      title: t("rail.finished", { count: finished.length }),
      tone: "muted",
    });
  finished.forEach(workflow);
  return rows;
}
