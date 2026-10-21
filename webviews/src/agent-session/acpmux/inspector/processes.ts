// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when the Inspector shows, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so the Inspector's Servers and Background
// tasks read the same thing for every harness. A dev server is told apart by its command alone
// (`serverOf`): cmux-next never scans processes or ports.
//
// The transcript knows commands too: Claude's background Bash calls, those Ctrl-B moved there
// included (conversation/runInBackground.ts), and their `background_task_update` ends
// (summary/sessionSummary.ts). `backgroundCommands` merges the two into the one list the
// Inspector's Background tasks, the summary card, the running turn's line and the transcript's
// "Running in background" row read. The registry wins: a transcript task whose call started a
// listed process is that process.
import { useEffect, useState } from "react";
import type { SummaryBackgroundTask } from "../summary/sessionSummary";

export type InspectorProcess = {
  /// acpmux's id, `<sessionId>/<task id>`: what `_acpmux/process/kill` takes.
  id: string;
  /// The Bash or exec call that started it: the transcript's background task of the same id is
  /// this process (`backgroundCommands`), and its terminal opens by it (processTerminal.ts).
  toolCallId?: string;
  command: string;
  /// Unix ms.
  startedAt: number;
  endedAt?: number;
  /// `running`, `exited`, `failed`, `killed` or `lost`.
  state: string;
};

/// One wire record for chat `sessionId`, or undefined for another chat's or a malformed one.
function processOf(value: unknown, sessionId: string): InspectorProcess | undefined {
  const raw = (value ?? {}) as Record<string, unknown>;
  if (typeof raw.id !== "string" || raw.sessionId !== sessionId) return undefined;
  if (typeof raw.command !== "string" || typeof raw.state !== "string" || typeof raw.startedAt !== "number")
    return undefined;
  return {
    id: raw.id,
    ...(typeof raw.toolCallId === "string" && raw.toolCallId ? { toolCallId: raw.toolCallId } : {}),
    command: raw.command,
    startedAt: raw.startedAt,
    ...(typeof raw.endedAt === "number" ? { endedAt: raw.endedAt } : {}),
    state: raw.state,
  };
}

/// The chat's processes from a `process/list` reply, in the order they started.
export function processesOf(reply: unknown, sessionId: string): InspectorProcess[] {
  const list = (reply as { processes?: unknown } | undefined)?.processes;
  return (Array.isArray(list) ? list : []).flatMap((value) => {
    const process = processOf(value, sessionId);
    return process ? [process] : [];
  });
}

/// `processes` with a `process_update`'s record in place of its old one, or added last; the same
/// array when the record is another chat's.
export function mergeProcess(
  processes: readonly InspectorProcess[],
  value: unknown,
  sessionId: string,
): readonly InspectorProcess[] {
  const process = processOf(value, sessionId);
  if (!process) return processes;
  const index = processes.findIndex((known) => known.id === process.id);
  return index < 0 ? [...processes, process] : processes.map((known, at) => (at === index ? process : known));
}

/// What the pane's acpmux client offers for them.
export type ProcessSource = {
  listProcesses(sessionId: string): Promise<unknown>;
  /// Registers the `process_update` listener; returns its removal.
  watchProcesses(listener: (process: unknown) => void): () => void;
};

/// What the registry says of a chat: its processes, and whether a `process/list` answered for it
/// (without one, only the updates since the subscription are known).
export type ProcessRegistry = { processes: readonly InspectorProcess[]; listed: boolean };

const NO_PROCESSES: ProcessRegistry = { processes: [], listed: false };

/// Chat `sessionId`'s background processes while `live`, and while one it knows still runs (so its
/// end arrives), kept current from the registry's updates. A listing that fails leaves what the
/// updates said. Going quiet keeps the last records, and the next listing replaces them, so a
/// count does not drop to zero and back.
export function useProcessRegistry(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): ProcessRegistry {
  const [state, setState] = useState<ProcessRegistry & { sessionId?: string }>(NO_PROCESSES);
  const running = state.sessionId === sessionId && state.processes.some((process) => process.state === "running");
  const on = live || running;
  useEffect(() => {
    if (!source || !sessionId || !on) return;
    let current = true;
    // This subscription's updates: newer than the list's records.
    let updates: readonly InspectorProcess[] = [];
    setState((known) => (known.sessionId === sessionId ? known : { sessionId, processes: [], listed: false }));
    const stop = source.watchProcesses((value) => {
      updates = mergeProcess(updates, value, sessionId);
      setState((known) => {
        const processes = known.sessionId === sessionId ? known.processes : [];
        const listed = known.sessionId === sessionId && known.listed;
        const next = mergeProcess(processes, value, sessionId);
        return next === processes && known.sessionId === sessionId ? known : { sessionId, processes: next, listed };
      });
    });
    source.listProcesses(sessionId).then(
      (reply) => {
        if (!current) return;
        const listed = processesOf(reply, sessionId);
        setState({
          sessionId,
          processes: updates.reduce<readonly InspectorProcess[]>(
            (all, process) => mergeProcess(all, { ...process, sessionId }, sessionId),
            listed,
          ),
          // A reply without its list (a daemon that does not keep one) lists nothing.
          listed: Array.isArray((reply as { processes?: unknown } | undefined)?.processes),
        });
      },
      () => undefined,
    );
    return () => {
      current = false;
      stop();
    };
  }, [source, sessionId, on]);
  return state.sessionId === sessionId ? state : NO_PROCESSES;
}

/// Chat `sessionId`'s background processes while `live` (the Inspector shows), kept current from
/// the registry's updates. A listing that fails leaves what the updates said.
export function useInspectorProcesses(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): readonly InspectorProcess[] {
  return useProcessRegistry(source, sessionId, live).processes;
}

/// One background command, from the registry or only the transcript.
export type BackgroundCommand = {
  /// The registry's process id, else the transcript's tool call id.
  id: string;
  command: string;
  /// A registry process acpmux lost track of (its daemon restarted) is `lost`; the transcript
  /// never says so.
  state: SummaryBackgroundTask["state"] | "lost";
  /// The call that started it: its terminal opens by it (processTerminal.ts).
  toolCallId?: string;
  /// The registry's id, which Stop (`_acpmux/process/kill`) takes; none for a transcript-only one.
  processId?: string;
  /// Epoch ms, for its elapsed time.
  startedAt?: number;
  endedAt?: number;
};

/// A registry state as a command's: `exited` finished, `killed` stopped.
const PROCESS_STATE: Record<string, BackgroundCommand["state"]> = {
  running: "running",
  exited: "completed",
  failed: "failed",
  killed: "stopped",
  lost: "lost",
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

/// A command that serves something: a framework's dev server, a static file server or a backend.
const SERVER_COMMAND = new RegExp(
  [
    String.raw`\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:dev|start|serve|preview|storybook)\b`,
    String.raw`\b(?:vite(?!\s+build)|next\s+(?:dev|start)|astro\s+dev|nuxt\s+dev|remix\s+dev|wrangler\s+dev|vercel\s+dev)\b`,
    String.raw`\b(?:rails\s+s(?:erver)?|manage\.py\s+runserver|flask\s+run|uvicorn|gunicorn|hypercorn|fastapi\s+(?:dev|run))\b`,
    String.raw`\b(?:http\.server|http-server|live-server|webpack(?:-dev-server|\s+serve)|storybook\s+dev|expo\s+start)\b`,
    String.raw`\b(?:php\s+-S|hugo\s+server|jekyll\s+serve|docusaurus\s+start|mkdocs\s+serve|deno\s+task\s+dev)\b`,
  ].join("|"),
);
/// A port the command names: `--port 3000`, `--port=3000`, `PORT=3000`, `localhost:3000`, `-p 3000`
/// (only on a server command), and `http.server 8000` or `runserver 8000`.
const PORTS = [
  /(?:^|\s)--port[= ](\d{2,5})\b/g,
  /\bPORT=(\d{2,5})\b/g,
  /\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})\b/g,
  /\b(?:http\.server|runserver)\s+(?:[\w.]+:)?(\d{2,5})\b/g,
];
const SHORT_PORT = /(?:^|\s)-p\s+(\d{2,5})\b/g;

export type InspectorServer = InspectorProcess & {
  /// The ports the command names, in the order named; empty when it names none (the default port
  /// is never guessed).
  readonly ports: readonly number[];
};

/// `process` as a server, or undefined for any other background command.
export function serverOf(process: InspectorProcess): InspectorServer | undefined {
  const command = process.command;
  const server = SERVER_COMMAND.test(command);
  const ports = new Set<number>();
  for (const pattern of server ? [...PORTS, SHORT_PORT] : PORTS)
    for (const match of command.matchAll(pattern)) {
      const port = Number(match[1]);
      if (port > 0 && port < 65536) ports.add(port);
    }
  if (!server && ports.size === 0) return undefined;
  return { ...process, ports: [...ports] };
}

/// The chat's processes split into the running servers and every other process; a server that
/// ended counts as a finished background task.
export function splitServers(processes: readonly InspectorProcess[]): {
  servers: InspectorServer[];
  tasks: InspectorProcess[];
} {
  const servers: InspectorServer[] = [];
  const tasks: InspectorProcess[] = [];
  for (const process of processes) {
    const server = process.state === "running" ? serverOf(process) : undefined;
    if (server) servers.push(server);
    else tasks.push(process);
  }
  return { servers, tasks };
}
