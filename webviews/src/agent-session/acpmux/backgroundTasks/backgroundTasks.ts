// The Background tasks panel's model (BackgroundTasksPanel.tsx): every piece of work the chat runs
// beside its turn, grouped by who runs it, the way Claude Desktop's Background tasks panel groups it
// (Leo, 2026-10-29: "i like these tasks i like the order that things split on the right i want that
// in cmux next").
//
// One group per agent: each of the chat's subagents (its own tool calls are its tasks, its nested
// subagents are tasks that open in turn), each chat the agent started (a child session, which has no
// tasks of its own here), and the chat's own background commands under the chat's name. Inside a
// group the running tasks come first, oldest first, then the finished ones, the latest first, which
// the panel folds under "N finished". The group's counts line ("39 tasks, 3 failed") counts both.
//
// All of it is derived from acpmux's snapshot: the rows and `subagentViews` (subagentFold.ts), the
// process registry's commands (inspector/processes.ts `backgroundCommands`) and the started chats
// (started/startedSessions.ts). Nothing here is kept by hand; the panel's own state is which groups
// the person cleared (`dismissed`) and which are open.
//
// Cost: a group's tasks are read from its subagent's view once per view array (`TaskCache`, keyed by
// the array, which subagentFold.ts replaces only when that subagent's rows change), so a snapshot that
// streams the chat's own reply re-reads no subagent's rows. The panel computes it only while it is
// open (App.tsx), so a closed panel adds no work per snapshot.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import type { BackgroundCommand } from "../inspector/processes";
import type { StartedSession } from "../started/startedSessions";
import { subagentsIn } from "../subagents/subagentRows";
import type { Subagent } from "../subagents/subagentFold";

/// A task's or a group's state. `stopped` is a cancel, a disconnect or a call its agent left
/// unfinished when it ended; only `failed` counts as a failure.
export type BackgroundState = "running" | "done" | "failed" | "stopped";

/// What Stop on a running row stops: a subagent (`stopSubagent`) or a registry process
/// (`_acpmux/process/kill`). A row with neither has no stop button.
export type StopTarget = { kind: "agent"; id: string } | { kind: "process"; id: string };

export type BackgroundTask = {
  /// The tool call's id, a nested subagent's id or a command's id: stable across snapshots.
  id: string;
  kind: "tool" | "agent" | "command";
  title: string;
  state: BackgroundState;
  /// Epoch ms on the session's clock; none when the harness never said.
  startedAt?: number;
  endedAt?: number;
  /// The subagent whose transcript holds the task (the group's own, or for a nested subagent
  /// itself): clicking the task opens that transcript in the panel, scrolled to `rowId`.
  agentId?: string;
  rowId?: string;
  /// A command's tool call, which its terminal opens by (processTerminal.ts).
  toolCallId?: string;
  stop?: StopTarget;
};

export type BackgroundGroup = {
  /// `agent:<subagent id>`, `chat:<session id>` or `commands`.
  id: string;
  kind: "agent" | "chat" | "commands";
  name: string;
  state: BackgroundState;
  startedAt?: number;
  endedAt?: number;
  /// Running first (oldest first), then the finished ones (the latest first).
  running: BackgroundTask[];
  finished: BackgroundTask[];
  /// Tasks in all, and how many of them failed: the counts line.
  total: number;
  failed: number;
  /// The subagent the group is (drills into its transcript), or the started chat (opens it).
  agentId?: string;
  sessionId?: string;
  stop?: StopTarget;
};

export type BackgroundInput = {
  rows: readonly AcpmuxRow[];
  views?: Record<string, AcpmuxRow[]>;
  commands: readonly BackgroundCommand[];
  sessions: readonly StartedSession[];
  /// The chat's name, which heads the group of its own background commands.
  chatName: string;
  /// Groups the person cleared (Clear finished): ended groups whose id is here are left out. A
  /// group that runs again (a restarted subagent keeps its id) shows again.
  dismissed?: ReadonlySet<string>;
};

/// A subagent's tasks by the view array they were read from (see the header's Cost).
export type TaskCache = WeakMap<readonly AcpmuxRow[], { running: boolean; tasks: BackgroundTask[] }>;

const toolState = (status: string | undefined, agentRunning: boolean): BackgroundState => {
  if (status === "failed") return "failed";
  if (status === "cancelled") return "stopped";
  if (status === "pending" || status === "in_progress") return agentRunning ? "running" : "stopped";
  return "done";
};

export const agentState = (agent: Pick<Subagent, "state">): BackgroundState =>
  agent.state === "running"
    ? "running"
    : agent.state === "failed"
      ? "failed"
      : agent.state === "completed"
        ? "done"
        : "stopped";

const commandState = (command: BackgroundCommand): BackgroundState =>
  command.state === "running"
    ? "running"
    : command.state === "failed"
      ? "failed"
      : command.state === "lost" || command.state === "stopped"
        ? "stopped"
        : "done";

const sessionState = (session: StartedSession): BackgroundState =>
  session.state === "running" || session.state === "waiting"
    ? "running"
    : session.state === "failed"
      ? "failed"
      : "done";

/// A tool call's name in the list: what the harness says it does (Claude's `description`), else its
/// title.
const toolTitle = (item: AcpmuxActivity): string =>
  item.tool?.description?.trim() || item.tool?.title?.trim() || item.text.trim();

/// The tool calls in subagent `agent`'s own rows, in order, as tasks. Read once per view array.
function toolTasks(agent: Subagent, view: readonly AcpmuxRow[] | undefined, cache: TaskCache): BackgroundTask[] {
  if (!view || view.length === 0) return [];
  const running = agent.state === "running";
  const kept = cache.get(view);
  // A kept list is right while the agent's running state is the one it was read under: a call
  // left in flight reads `stopped` once the agent ended.
  if (kept?.running === running) return kept.tasks;
  const tasks: BackgroundTask[] = [];
  for (const row of view) {
    for (const item of row.items ?? []) {
      const call = item.tool;
      if (item.kind !== "tool" || !call) continue;
      tasks.push({
        id: call.id,
        kind: "tool",
        title: toolTitle(item),
        state: toolState(call.status, running),
        startedAt: call.startedAt ?? item.startedAt ?? row.at,
        endedAt: call.endedAt ?? item.endedAt,
        agentId: agent.id,
        rowId: row.id,
      });
    }
  }
  cache.set(view, { running, tasks });
  return tasks;
}

const byStart = (a: { startedAt?: number; id: string }, b: { startedAt?: number; id: string }) =>
  (a.startedAt ?? 0) - (b.startedAt ?? 0) || a.id.localeCompare(b.id);
const byLatestEnd = (a: BackgroundTask, b: BackgroundTask) =>
  (b.endedAt ?? b.startedAt ?? 0) - (a.endedAt ?? a.startedAt ?? 0) || a.id.localeCompare(b.id);

/// Splits tasks into running (oldest first) and finished (the latest first) and counts them.
function split(tasks: readonly BackgroundTask[]) {
  const running = tasks.filter((task) => task.state === "running").sort(byStart);
  const finished = tasks.filter((task) => task.state !== "running").sort(byLatestEnd);
  const failed = finished.reduce((n, task) => n + (task.state === "failed" ? 1 : 0), 0);
  return { running, finished, total: tasks.length, failed };
}

/// A group is live while it or any of its tasks runs: an agent that ended with a nested agent
/// still running stays with the running groups and is never cleared.
export const isLive = (group: BackgroundGroup): boolean => group.state === "running" || group.running.length > 0;

/// The panel's groups: the running ones first, oldest first, so a group never jumps while it runs;
/// then the ended ones, the latest first. Cleared groups that ended are left out.
export function backgroundGroups(input: BackgroundInput, cache: TaskCache = new WeakMap()): BackgroundGroup[] {
  const { rows, views, commands, sessions, chatName, dismissed } = input;
  const agents = subagentsIn(rows, views);
  const children = new Map<string, Subagent[]>();
  for (const agent of agents.values()) {
    if (agent.parent === null || !agents.has(agent.parent)) continue;
    const list = children.get(agent.parent) ?? [];
    list.push(agent);
    children.set(agent.parent, list);
  }
  const groups: BackgroundGroup[] = [];
  for (const agent of agents.values()) {
    // A nested subagent is a task of the one that spawned it, unless that one is unknown.
    if (agent.parent !== null && agents.has(agent.parent)) continue;
    const tasks = [...toolTasks(agent, views?.[agent.id], cache)];
    // Every descendant, not only the direct children, so an agent nested two deep (A spawns B,
    // B spawns C) still shows, opens and stops from A's group.
    const descendants: Subagent[] = [];
    const stack = [...(children.get(agent.id) ?? [])];
    const seen = new Set<string>([agent.id]);
    while (stack.length > 0) {
      const next = stack.shift()!;
      if (seen.has(next.id)) continue;
      seen.add(next.id);
      descendants.push(next);
      stack.push(...(children.get(next.id) ?? []));
    }
    for (const child of descendants)
      tasks.push({
        id: child.id,
        kind: "agent",
        title: child.task?.trim() || child.name,
        state: agentState(child),
        startedAt: child.startedAt,
        endedAt: child.endedAt,
        agentId: child.id,
        ...(child.state === "running" && { stop: { kind: "agent", id: child.id } as StopTarget }),
      });
    const state = agentState(agent);
    groups.push({
      id: `agent:${agent.id}`,
      kind: "agent",
      name: agent.task?.trim() || agent.name,
      state,
      startedAt: agent.startedAt,
      endedAt: agent.endedAt,
      agentId: agent.id,
      ...(state === "running" && { stop: { kind: "agent", id: agent.id } as StopTarget }),
      ...split(tasks),
    });
  }
  for (const session of sessions) {
    const state = sessionState(session);
    groups.push({
      id: `chat:${session.sessionId}`,
      kind: "chat",
      name: session.title?.trim() || session.sessionId,
      state,
      startedAt: session.createdAt,
      sessionId: session.sessionId,
      running: [],
      finished: [],
      total: 0,
      failed: 0,
    });
  }
  if (commands.length > 0) {
    const tasks: BackgroundTask[] = commands.map((command) => ({
      id: command.id,
      kind: "command",
      title: command.description?.trim() || command.command,
      state: commandState(command),
      startedAt: command.startedAt,
      endedAt: command.endedAt,
      toolCallId: command.toolCallId,
      ...(command.state === "running" &&
        command.processId !== undefined && { stop: { kind: "process", id: command.processId } as StopTarget }),
    }));
    const parts = split(tasks);
    const starts = tasks.map((task) => task.startedAt).filter((at): at is number => at !== undefined);
    const ends = tasks.map((task) => task.endedAt).filter((at): at is number => at !== undefined);
    groups.push({
      id: "commands",
      kind: "commands",
      name: chatName,
      state:
        parts.running.length > 0
          ? "running"
          : parts.failed > 0
            ? "failed"
            : tasks.some((task) => task.state === "stopped")
              ? "stopped"
              : "done",
      startedAt: starts.length > 0 ? Math.min(...starts) : undefined,
      endedAt: parts.running.length > 0 || ends.length === 0 ? undefined : Math.max(...ends),
      ...parts,
    });
  }
  const live = groups.filter(isLive).sort(byStart);
  const ended = groups
    .filter((group) => !isLive(group) && !dismissed?.has(group.id))
    .sort((a, b) => (b.endedAt ?? b.startedAt ?? 0) - (a.endedAt ?? a.startedAt ?? 0) || a.id.localeCompare(b.id));
  return [...live, ...ended];
}

/// What Clear finished clears: every group with nothing left running (one whose agent ended while
/// a nested agent or command of it still runs stays).
export const finishedGroupIds = (groups: readonly BackgroundGroup[]): string[] =>
  groups.filter((group) => !isLive(group)).map((group) => group.id);

/// Whether anything runs: the panel's clock ticks only then (SubagentGroup.tsx `useNow`).
export const anyRunning = (groups: readonly BackgroundGroup[]): boolean => groups.some(isLive);
