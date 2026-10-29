// Session Info's Background tasks as the App draws it (model.ts): what ChatInspector's `tasks`,
// WorkflowTasks.tsx, ServersSection.tsx and TasksSection.tsx show, as plain rows. The chat's Claude
// workflows first (running, then finished; each with its phases and, in an open phase, its agents),
// then the dev servers, then the running commands and the scheduled wakeups, then "N finished",
// which opens into the ended commands. The lists, their order and their words come from the page's
// own helpers, so both panels say the same thing.
import { formatDuration } from "../../conversation/turns";
import type { StringKey, Translate } from "../../i18n";
import { openCommand } from "../../processTerminal";
import { phaseAgents, tally, upNext } from "../../summary/foldWorkflows";
import type { SummaryBackgroundTask, SummaryWakeup } from "../../summary/sessionSummary";
import type { WorkflowAgent, WorkflowSummary } from "../../summary/workflow";
import {
  arrivalKey,
  inspectorLists,
  sendLabel,
  splitCommands,
  type BackgroundCommand,
  type InspectorProcess,
} from "../processes";
import { COMMAND_STATE, commandClosed } from "../TasksSection";
import {
  agentStateWord,
  isRunning,
  phaseLabel,
  phaseOpensAlone,
  workflowAgentModel,
  workflowAgentTime,
  workflowElapsed,
  workflowMeta,
} from "../WorkflowTasks";
import type { NativeInfoActions, NativeInfoButton, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";

export type TasksSectionInput = {
  /// The section is unfolded (ChatInspector's `state.tasks`).
  open: boolean;
  /// The registry's processes, the transcript's background tasks and whether the registry listed the
  /// chat: split into servers and commands as ChatInspector does (`inspectorLists`).
  processes: readonly InspectorProcess[];
  transcriptTasks: readonly SummaryBackgroundTask[];
  listed: boolean;
  /// The wakeups and cron jobs the agent scheduled (sessionSummary `scheduled`).
  scheduled: readonly SummaryWakeup[];
  /// The chat's Claude workflows (Labs).
  workflows: readonly WorkflowSummary[];
  /// The chat runs on this Mac (processTerminal.ts `opensProcessTerminal`): a command's terminal opens.
  local: boolean;
  /// The tool calls the loaded transcript holds (ChatInspector's `calls`): a row whose call is among
  /// them can show it.
  calls?: ReadonlySet<string>;
  onShowCall?: (toolCallId: string) => boolean;
  onStopProcess?: (id: string) => Promise<unknown>;
  onStopWorkflow?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  onOpenUrl?: (url: string) => void;
  /// The clock the elapsed times read (the page's `useNow`).
  now: number;
  /// The finished commands show under "N finished"; `onFinishedOpen` flips it.
  finishedOpen?: boolean;
  onFinishedOpen?: (open: boolean) => void;
  /// A workflow phase the person opened or closed, by `<workflow id>/<phase id>`; one not named opens
  /// on its own while its agents run (WorkflowTasks `phaseOpensAlone`). `onPhase` flips one.
  phases?: Readonly<Record<string, boolean>>;
  onPhase?: (key: string, open: boolean) => void;
};

const COMMAND_TONE: Record<BackgroundCommand["state"], NativeInfoTone> = {
  running: "running",
  completed: "done",
  failed: "failed",
  stopped: "muted",
  lost: "muted",
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
/// scheduled task (ChatInspector's condition).
export function tasksSection(
  input: TasksSectionInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { servers, tasks: commands } = inspectorLists(input.processes, input.transcriptTasks, input.listed);
  const { workflows, scheduled, now } = input;
  if (servers.length + commands.length + scheduled.length + workflows.length === 0) return undefined;
  const stop = (id: string, name: string, run: (id: string) => Promise<unknown>, key: string): NativeInfoButton => ({
    label: t("subagents.stop", { name }),
    symbol: "stop.fill",
    action: actions.add(key, () => run(id)),
  });
  const rows: NativeInfoRow[] = [...workflowRows(input, actions, t, stop)];

  // Servers, newest first: the command, the ports it names (the first opens on a click, the others
  // by their buttons) and how long it has run.
  for (const server of [...servers].sort((a, b) => b.startedAt - a.startedAt)) {
    const urls = server.ports.map((port) => `http://localhost:${port}`);
    const onOpenUrl = input.onOpenUrl;
    const buttons: NativeInfoButton[] = [];
    if (onOpenUrl)
      for (const url of urls.slice(1))
        buttons.push({
          label: t("chatInspector.servers.open", { url }),
          symbol: "link",
          action: actions.add(`tasks.openUrl:${server.id}:${url}`, () => onOpenUrl(url)),
        });
    if (input.onStopProcess) buttons.push(stop(server.id, server.command, input.onStopProcess, `tasks.stop:${server.id}`));
    rows.push({
      id: `server:${server.id}`,
      symbol: "server.rack",
      title: server.command,
      detail: formatDuration(Math.max(0, now - server.startedAt)),
      ...(server.ports.length > 0 ? { trailing: server.ports.map((port) => `:${port}`).join(" ") } : {}),
      tone: "running",
      ...(onOpenUrl && urls[0]
        ? {
            action: actions.add(`tasks.openUrl:${server.id}`, () => onOpenUrl(urls[0]!)),
            help: t("chatInspector.servers.open", { url: urls[0] }),
          }
        : {}),
      ...(buttons.length > 0 ? { buttons } : {}),
    });
  }

  const { running, finished } = splitCommands(commands);
  const command = (item: BackgroundCommand, trailing: string | undefined): NativeInfoRow => {
    const key = arrivalKey(item);
    const why: StringKey | undefined = commandClosed(item.toolCallId, input);
    const onStop = input.onStopProcess;
    return {
      id: `command:${key}`,
      symbol: "terminal",
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
  for (const wakeup of scheduled)
    rows.push({
      id: `scheduled:${wakeup.id}`,
      symbol: "clock",
      title: wakeup.text,
      ...(wakeup.cron ? { trailing: wakeup.cron } : {}),
    });
  if (finished.length > 0) {
    const finishedOpen = input.finishedOpen ?? false;
    const onFinishedOpen = input.onFinishedOpen;
    rows.push({
      id: "finished",
      symbol: finishedOpen ? "chevron.down" : "chevron.right",
      title: t("rail.finished", { count: finished.length }),
      tone: "muted",
      ...(onFinishedOpen ? { action: actions.add("tasks.finished", () => onFinishedOpen(!finishedOpen)) } : {}),
    });
    if (finishedOpen)
      for (const item of finished) {
        const time =
          item.endedAt !== undefined && item.startedAt !== undefined
            ? formatDuration(Math.max(0, item.endedAt - item.startedAt))
            : undefined;
        rows.push(command(item, [time, t(COMMAND_STATE[item.state])].filter(Boolean).join(" · ")));
      }
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

/// WorkflowTasks' rows: "N running" and "N finished" heads when both show, each workflow (its time,
/// Stop while it runs, its counts under it), its phases (indent 1, a click folds one) and an open
/// phase's agents (indent 2), then "Up next".
function workflowRows(
  input: TasksSectionInput,
  actions: NativeInfoActions,
  t: Translate,
  stop: (id: string, name: string, run: (id: string) => Promise<unknown>, key: string) => NativeInfoButton,
): NativeInfoRow[] {
  const rows: NativeInfoRow[] = [];
  const running = input.workflows.filter(isRunning);
  const finished = input.workflows.filter((workflow) => !isRunning(workflow));
  const both = running.length > 0 && finished.length > 0;
  const workflow = (item: WorkflowSummary) => {
    const live = isRunning(item);
    const elapsed = workflowElapsed(item, input.now);
    const meta = workflowMeta(t, item);
    const onStop = input.onStopWorkflow;
    rows.push({
      id: `workflow:${item.id}`,
      symbol: "point.3.connected.trianglepath.dotted",
      title: item.title,
      ...(meta.length > 0 ? { subtitle: meta.join(" · ") } : {}),
      ...(elapsed !== undefined ? { trailing: formatDuration(elapsed) } : {}),
      tone: WORKFLOW_TONE[item.state],
      ...(item.description ? { help: item.description } : {}),
      ...(live && onStop ? { buttons: [stop(item.id, item.title, onStop, `tasks.stopWorkflow:${item.id}`)] } : {}),
    });
    const next = live ? upNext(item) : [];
    const listed = live ? item.phases.filter((phase) => !next.includes(phase)) : item.phases;
    for (const phase of listed) {
      const agents = phaseAgents(item, phase);
      const counts = tally(agents);
      const key = `${item.id}/${phase.id}`;
      const open = input.phases?.[key] ?? phaseOpensAlone(live, counts);
      const onPhase = input.onPhase;
      const label = phaseLabel(t, counts, live);
      rows.push({
        id: `phase:${key}`,
        symbol: open ? "chevron.down" : "chevron.right",
        title: phase.name || t("workflow.unassigned"),
        ...(label ? { trailing: label } : {}),
        tone: WORKFLOW_TONE[phase.state],
        indent: 1,
        ...(onPhase ? { action: actions.add(`tasks.phase:${key}`, () => onPhase(key, !open)) } : {}),
      });
      if (!open) continue;
      for (const agent of agents) {
        const model = workflowAgentModel(t, agent);
        const message = agent.lastMessage ?? agent.doing;
        const onOpen = input.onOpenWorkflowAgent;
        rows.push({
          id: `workflowAgent:${item.id}/${agent.id}`,
          symbol: "bubble.left",
          title: agent.name,
          ...(model ? { detail: model } : {}),
          ...(message ? { subtitle: message, help: message } : {}),
          trailing: [agentStateWord(t, agent.state), workflowAgentTime(agent, input.now)].filter(Boolean).join(" · "),
          tone: WORKFLOW_TONE[agent.state],
          indent: 2,
          ...(onOpen ? { action: actions.add(`tasks.openWorkflowAgent:${item.id}/${agent.id}`, () => onOpen(agent)) } : {}),
        });
      }
    }
    if (next.length > 0)
      rows.push({
        id: `upNext:${item.id}`,
        title: t("workflow.upNext", { phases: next.map((phase) => phase.name).join(", ") }),
        tone: "muted",
        indent: 1,
      });
  };
  if (both) rows.push({ id: "workflows.running", title: t("rail.running", { count: running.length }), tone: "muted" });
  running.forEach(workflow);
  if (both)
    rows.push({ id: "workflows.finished", title: t("rail.finished", { count: finished.length }), tone: "muted" });
  finished.forEach(workflow);
  return rows;
}
