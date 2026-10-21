// The chat's work that goes on outside its turn: commands it runs in the background and chats its
// agent started. The summary card lists them (SummaryTasks.tsx, ChildSessionRows.tsx), and the tray
// above the composer shows what still runs (subagents/runningTray.ts `trayItems`); with the tray
// off in Debug Settings, the running turn's line counts them (conversation/WorkingFor.tsx).
//
// Commands come from two places. acpmux's process registry (inspector/processes.ts) knows every
// harness's background commands and how each ended; the transcript knows Claude's background Bash
// calls and their `background_task_update` ends (sessionSummary.ts). The registry wins: a
// transcript task whose call started a listed process is that process.
import type { StartedSession } from "../started/startedSessions";
import type { SummaryBackgroundTask } from "./sessionSummary";
import type { InspectorProcess } from "../inspector/processes";

/// One background command as the card lists it.
export type BackgroundCommand = {
  /// The registry's process id, else the transcript's tool call id.
  id: string;
  command: string;
  state: SummaryBackgroundTask["state"];
  /// The call that started it: its terminal opens by it (processTerminal.ts).
  toolCallId?: string;
  /// The registry's id, which Stop (`_acpmux/process/kill`) takes; none for a transcript-only one.
  processId?: string;
  /// Epoch ms, for its elapsed time.
  startedAt?: number;
  endedAt?: number;
};

/// A registry state as the card says it: `exited` finished, `killed` and `lost` stopped.
const PROCESS_STATE: Record<string, BackgroundCommand["state"]> = {
  running: "running",
  exited: "completed",
  failed: "failed",
  killed: "stopped",
  lost: "stopped",
};

/// The chat's background commands: the registry's processes, then the transcript's tasks no process
/// stands for. Once the registry has listed the chat (`listed`), it knows every command still
/// running, so a transcript task it does not know that still says running (a record from before the
/// registry, or one that ended unseen) is left out rather than shown running forever.
export function backgroundCommands(
  processes: readonly InspectorProcess[],
  transcript: readonly SummaryBackgroundTask[],
  listed: boolean,
): BackgroundCommand[] {
  const fromRegistry = processes.map((process): BackgroundCommand => ({
    id: process.id,
    command: process.command,
    state: PROCESS_STATE[process.state] ?? "stopped",
    processId: process.id,
    startedAt: process.startedAt,
    ...(process.toolCallId ? { toolCallId: process.toolCallId } : {}),
    ...(process.endedAt !== undefined ? { endedAt: process.endedAt } : {}),
  }));
  const known = new Set(processes.flatMap((process) => (process.toolCallId ? [process.toolCallId] : [])));
  const fromTranscript = transcript
    .filter((task) => !known.has(task.id) && !(listed && task.state === "running"))
    .map((task): BackgroundCommand => ({
      id: task.id,
      command: task.command,
      state: task.state,
      toolCallId: task.id,
      ...(task.startedAt !== undefined ? { startedAt: task.startedAt } : {}),
    }));
  return [...fromRegistry, ...fromTranscript];
}

const newestFirst = (a: BackgroundCommand, b: BackgroundCommand) =>
  (b.startedAt ?? -Infinity) - (a.startedAt ?? -Infinity);

/// The running commands newest first, and the finished ones newest first.
export function splitCommands(commands: readonly BackgroundCommand[]): {
  running: BackgroundCommand[];
  finished: BackgroundCommand[];
} {
  return {
    running: commands.filter((command) => command.state === "running").sort(newestFirst),
    finished: commands.filter((command) => command.state !== "running").sort(newestFirst),
  };
}

/// The started chats as the card lists them: waiting on the person first, then running, failed and
/// idle, each newest first.
export function orderedSessions(sessions: readonly StartedSession[]): StartedSession[] {
  const rank = { waiting: 0, running: 1, failed: 2, idle: 3 } as const;
  return [...sessions].sort(
    (a, b) => rank[a.state] - rank[b.state] || (b.createdAt ?? -Infinity) - (a.createdAt ?? -Infinity),
  );
}
