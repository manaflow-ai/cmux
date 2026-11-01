// Session Info for a subagent (Leo, 2026-10-21: "the top right session sidebar summary thing;
// subagent should have its own instance of it like it might have different env worktree context bg
// tasks outputs and diffs etc"). While the pane shows a subagent's own view (its line in a group,
// the tray, or a pane of its own: App.tsx `subagentView`), Session Info lists that subagent's
// things only, read from its own rows (the snapshot's `subagentViews[id]`), never merged with the
// chat's:
//
// - Environment: the chat's machine; the subagent's folder, worktree and branch when the harness
//   reports them (subagentFold.ts: Claude's `isolation: "worktree"`, the `worktreePath:` and
//   `worktreeBranch:` its result names, or the `.claude/worktrees/<name>` its tool calls work in),
//   else the chat's folder and branch, which it shares; then the folders its own tool calls touched.
// - Context: the tokens and tool uses the harness reports for it (a subagent has no window of its
//   own in acpmux's summary).
// - Changes, Outputs and Background tasks: what its own tool calls opened, wrote and started; of the
//   registry's processes, only those its calls started.
// - Subagents: the ones it spawned, nested ones included.
// Connectors, Servers' Save and the chats the chat started stay on the chat's own panel.
//
// A chat the agent started with cmux-subsessions (`start_session`) is an acpmux session of its own:
// opened, it is its own chat, and Session Info is already its own.
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { Subagent } from "../subagents/subagentFold";
import type { SummaryBackgroundTask } from "../summary/sessionSummary";
import type { SessionInfoProcess } from "./processes";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// The subagent Session Info is scoped to, as App.tsx hands it over.
export type SubagentScope = {
  agent: Subagent;
  /// Its own rows (the snapshot's `subagentViews[id]`): its replies, thoughts and tool calls.
  rows: readonly AcpmuxRow[];
  /// What spawned it: the chat's name, or its parent subagent's.
  parent: string;
  /// The subagents it spawned, nested ones included.
  agents: readonly Subagent[];
  /// Shows what spawned it again: its parent subagent's view, or the chat's.
  onBack?: () => void;
};

/// A Claude Code worktree (`<repo>/.claude/worktrees/<name>`), from any path inside it.
const CLAUDE_WORKTREE = /^(\/.*?\/\.claude\/worktrees\/[^/]+)(?:\/|$)/;

/// The worktree a subagent's tool calls work in, when they name files inside a Claude Code worktree:
/// a subagent asked for one shows it before its result names it.
export function worktreeOfRows(rows: readonly AcpmuxRow[]): string | undefined {
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (!tool) continue;
      for (const path of [...(tool.diffs ?? []), ...(tool.locations ?? [])].map((entry) => entry.path)) {
        const found = CLAUDE_WORKTREE.exec(path)?.[1];
        if (found) return found;
      }
    }
  }
  return undefined;
}

/// Where the subagent works, as Session Info's Environment reads a summary: the chat's machine,
/// and its own folder, worktree and branch when the harness reports them. One that shares the chat's
/// checkout shares its folder and branch; one in a worktree of its own never shows the chat's
/// branch. No usage and no connectors: those are the chat's.
export function subagentSummary(
  chat: Summary | undefined,
  agent: Subagent,
  rows: readonly AcpmuxRow[],
): Summary | undefined {
  if (!chat) return undefined;
  const base: Summary = {
    sessionId: `${chat.sessionId}:subagent:${agent.id}`,
    ...(chat.host !== undefined ? { host: chat.host } : {}),
    ...(chat.peer !== undefined ? { peer: chat.peer } : {}),
    ...(chat.hostKind !== undefined ? { hostKind: chat.hostKind } : {}),
  };
  // A worktree its calls work in is its own only when the chat is not in that worktree already.
  const seen = worktreeOfRows(rows);
  const chatTree = chat.worktree ?? chat.cwd;
  const shared = seen !== undefined && chatTree !== undefined && (chatTree === seen || chatTree.startsWith(`${seen}/`));
  const worktree = agent.worktree?.path ?? (shared ? undefined : seen);
  if (worktree)
    return {
      ...base,
      // The folder it was given, when that is inside its worktree; else the worktree.
      cwd: agent.cwd && (agent.cwd === worktree || agent.cwd.startsWith(`${worktree}/`)) ? agent.cwd : worktree,
      worktree,
      ...(agent.worktree?.branch ? { branch: agent.worktree.branch } : {}),
    };
  const cwd = agent.cwd ?? chat.cwd;
  // Asked for a worktree it has not reported yet: its folder is the chat's until it does, its branch
  // unknown.
  if (agent.isolated) return { ...base, ...(cwd ? { cwd } : {}) };
  return {
    ...base,
    ...(cwd ? { cwd } : {}),
    ...(chat.branch ? { branch: chat.branch } : {}),
    ...(chat.worktree ? { worktree: chat.worktree } : {}),
  };
}

/// The tool calls in `rows`.
function callIds(rows: readonly AcpmuxRow[]): Set<string> {
  const ids = new Set<string>();
  for (const row of rows)
    if (row.kind === "activity") for (const item of row.items ?? []) if (item.tool) ids.add(item.tool.id);
  return ids;
}

/// The registry's processes the subagent's own calls started.
export function subagentProcesses(
  processes: readonly SessionInfoProcess[],
  rows: readonly AcpmuxRow[],
): readonly SessionInfoProcess[] {
  if (processes.length === 0) return processes;
  const ids = callIds(rows);
  return processes.filter((process) => process.toolCallId !== undefined && ids.has(process.toolCallId));
}

/// The subagents `id` spawned, at any depth, from every subagent the chat has.
export function descendants(all: Iterable<Subagent>, id: string): Subagent[] {
  const list = [...all];
  const parentOf = new Map(list.map((agent) => [agent.id, agent.parent] as const));
  const under = (agent: Subagent) => {
    const seen = new Set<string>();
    for (let parent = agent.parent; parent !== null && parent !== undefined; parent = parentOf.get(parent) ?? null) {
      if (parent === id) return true;
      if (seen.has(parent)) return false;
      seen.add(parent);
    }
    return false;
  };
  return list.filter(under);
}

/// The subagent's background commands with how they ended: a subagent's shell ending is noted in
/// the chat's own rows (direct.ts: a `backgroundTask` row, since the call that started it is in the
/// subagent's rows, not the chat's), so a running one looks there for its end.
export function withChatEnds(
  tasks: readonly SummaryBackgroundTask[],
  chatRows: readonly AcpmuxRow[],
): readonly SummaryBackgroundTask[] {
  if (!tasks.some((task) => task.state === "running")) return tasks;
  const ends = new Map<string, SummaryBackgroundTask["state"]>();
  for (const row of chatRows) if (row.backgroundTask) ends.set(row.backgroundTask.toolCallId, row.backgroundTask.state);
  if (ends.size === 0) return tasks;
  return tasks.map((task) => {
    const state = task.state === "running" ? ends.get(task.id) : undefined;
    return state ? { ...task, state } : task;
  });
}

/// The folder whose changes a subagent's edited files open in (the Changes viewer beside the chat,
/// `pane.action` changes): its own worktree when it has one, else its folder, else the chat's.
export function subagentChangesFolder(chat: Summary | undefined, scope: SubagentScope): string | undefined {
  const own = subagentSummary(chat, scope.agent, scope.rows);
  return own?.worktree ?? own?.cwd;
}
