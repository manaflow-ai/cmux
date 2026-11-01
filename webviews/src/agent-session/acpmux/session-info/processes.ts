// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when Session Info shows, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so Session Info's Servers and Background
// tasks read the same thing for every harness. A dev server is told apart by its command alone
// (`serverOf`): cmux-next never scans processes or ports.
//
// The transcript knows commands too: Claude's background Bash calls, those Ctrl-B moved there
// included (conversation/runInBackground.ts), and their `background_task_update` ends
// (summary/sessionSummary.ts). `backgroundCommands` merges the two into the one list the
// Session Info's Background tasks, the summary card, the running turn's line and the tray above the
// composer (subagents/runningTray.ts) read. The registry wins: a transcript task whose call started a
// listed process is that process.
import { acpmuxSend } from "../conversation/acpmuxSends";
import type { Translate } from "../i18n";
import { useEffect, useState } from "react";
import type { SummaryBackgroundTask } from "../summary/sessionSummary";

export type SessionInfoProcess = {
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
function processOf(value: unknown, sessionId: string): SessionInfoProcess | undefined {
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
export function processesOf(reply: unknown, sessionId: string): SessionInfoProcess[] {
  const list = (reply as { processes?: unknown } | undefined)?.processes;
  return (Array.isArray(list) ? list : []).flatMap((value) => {
    const process = processOf(value, sessionId);
    return process ? [process] : [];
  });
}

/// `processes` with a `process_update`'s record in place of its old one, or added last; the same
/// array when the record is another chat's.
export function mergeProcess(
  processes: readonly SessionInfoProcess[],
  value: unknown,
  sessionId: string,
): readonly SessionInfoProcess[] {
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
export type ProcessRegistry = { processes: readonly SessionInfoProcess[]; listed: boolean };

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
    let updates: readonly SessionInfoProcess[] = [];
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
          processes: updates.reduce<readonly SessionInfoProcess[]>(
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

/// Chat `sessionId`'s background processes while `live` (Session Info shows), kept current from
/// the registry's updates. A listing that fails leaves what the updates said.
export function useSessionInfoProcesses(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): readonly SessionInfoProcess[] {
  return useProcessRegistry(source, sessionId, live).processes;
}

/// One background command, from the registry or only the transcript.
export type BackgroundCommand = {
  /// The registry's process id, else the transcript's tool call id.
  id: string;
  command: string;
  /// What the call that started it says it does (Claude's Bash `description`): the tray names the
  /// command by it (`commandLabel`).
  description?: string;
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

/// The key a command enters its list under (ui/presence.ts `useArrivals`): the call that started it,
/// which stays when the registry lists a command only the transcript knew (its id becomes the
/// registry's).
export const arrivalKey = (command: BackgroundCommand) => command.toolCallId ?? command.id;

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
  processes: readonly SessionInfoProcess[],
  transcript: readonly SummaryBackgroundTask[],
  listed: boolean,
): BackgroundCommand[] {
  const described = new Map(transcript.flatMap((task) => (task.description ? [[task.id, task.description]] : [])));
  const fromRegistry = processes.map((process): BackgroundCommand => ({
    id: process.id,
    command: process.command,
    ...(process.toolCallId && described.has(process.toolCallId)
      ? { description: described.get(process.toolCallId) }
      : {}),
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
      ...(task.description ? { description: task.description } : {}),
      state: task.state,
      toolCallId: task.id,
      ...(task.startedAt !== undefined ? { startedAt: task.startedAt } : {}),
    }));
  return [...fromRegistry, ...fromTranscript];
}

/// A command's leading shell words, each with where it ends, and the `&&` or `;` that ends its
/// first part. One pass over the text, quotes kept whole: no pattern that can backtrack.
function leadingWords(text: string, from: number): { words: { word: string; end: number }[]; end: number } {
  const words: { word: string; end: number }[] = [];
  let index = from;
  for (;;) {
    while (index < text.length && /\s/.test(text[index]!)) index += 1;
    if (index >= text.length) return { words, end: -1 };
    if (text.startsWith("&&", index)) return { words, end: index + 2 };
    if (text[index] === ";") return { words, end: index + 1 };
    if (text[index] === "|" || text[index] === "&") return { words, end: -1 };
    let word = "";
    while (index < text.length && !/[\s;&|]/.test(text[index]!)) {
      const quote = text[index]!;
      if (quote === '"' || quote === "'") {
        const close = text.indexOf(quote, index + 1);
        const stop = close < 0 ? text.length : close + 1;
        word += text.slice(index, stop);
        index = stop;
      } else {
        word += quote;
        index += 1;
      }
    }
    words.push({ word, end: index });
  }
}

const ASSIGNMENT = /^[A-Za-z_]\w*=/;

/// What the tray names a command by: what its call says it does, else the command without what
/// only sets the stage in front of what it runs: `cd DIR &&` (or `;`), `export X=1 &&`, a part
/// that only assigns, and `env` or `X=1` before the program (the whole command when that is all
/// it is).
export function commandLabel(command: BackgroundCommand): string {
  if (command.description) return command.description;
  const text = command.command.trim();
  let from = 0;
  for (;;) {
    const { words, end } = leadingWords(text, from);
    const names = words.map(({ word }) => word);
    const staging =
      end > 0 &&
      names.length > 0 &&
      ((names[0] === "cd" && names.length <= 2) ||
        (names[0] === "export" && names.slice(1).every((word) => ASSIGNMENT.test(word))) ||
        names.every((word) => ASSIGNMENT.test(word)));
    if (!staging || !text.slice(end).trim()) break;
    from = end;
  }
  // `env` and assignments before the program it runs; `env` with options stays as it is.
  const { words } = leadingWords(text, from);
  let skip = words[0]?.word === "env" && !words[1]?.word.startsWith("-") ? 1 : 0;
  while (skip < words.length - 1 && ASSIGNMENT.test(words[skip]!.word)) skip += 1;
  const begin = skip > 0 ? words[skip - 1]!.end : from;
  return text.slice(begin).trim() || command.command;
}

/// A background command that sends another agent a message (conversation/acpmuxSends.ts) reads as
/// its transcript row does: "Sending message to tests", "Sent message to tests", "Couldn't send to
/// tests". Nil for every other command.
export function sendLabel(t: Translate, command: Pick<BackgroundCommand, "command" | "state">): string | undefined {
  const send = acpmuxSend(command.command);
  // Stopped or lost: whether it went is not known, so the command stays as typed. So does an ended
  // one whose exit status is another command's (`acpmux send … | tail -1`, `… && make`).
  if (!send || (command.state !== "running" && command.state !== "failed" && command.state !== "completed"))
    return undefined;
  if (command.state !== "running" && !send.ownsExit) return undefined;
  const key = command.state === "running" ? "send.sending" : command.state === "failed" ? "send.failed" : "send.sent";
  return t(key, { target: send.target });
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

export type SessionInfoServer = SessionInfoProcess & {
  /// The ports the command names, in the order named; empty when it names none (the default port
  /// is never guessed).
  readonly ports: readonly number[];
};

/// `process` as a server, or undefined for any other background command.
export function serverOf(process: SessionInfoProcess): SessionInfoServer | undefined {
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
export function splitServers(processes: readonly SessionInfoProcess[]): {
  servers: SessionInfoServer[];
  tasks: SessionInfoProcess[];
} {
  const servers: SessionInfoServer[] = [];
  const tasks: SessionInfoProcess[] = [];
  for (const process of processes) {
    const server = process.state === "running" ? serverOf(process) : undefined;
    if (server) servers.push(server);
    else tasks.push(process);
  }
  return { servers, tasks };
}

/// The ids of the registry's running servers: Session Info lists those commands under Servers,
/// never under Background tasks.
const servingIds = (processes: readonly SessionInfoProcess[]): ReadonlySet<string> =>
  new Set(splitServers(processes).servers.map((server) => server.id));

const served = (command: BackgroundCommand, serving: ReadonlySet<string>) =>
  command.processId !== undefined && serving.has(command.processId);

/// What Session Info lists: the registry's running servers under Servers, and every other
/// command (`backgroundCommands`, with all processes passed, so a transcript task a server stands
/// for is not listed again) under Background tasks.
export function sessionInfoLists(
  processes: readonly SessionInfoProcess[],
  transcript: readonly SummaryBackgroundTask[],
  listed: boolean,
): { servers: SessionInfoServer[]; tasks: BackgroundCommand[] } {
  const servers = splitServers(processes).servers;
  const serving = servingIds(processes);
  return {
    servers,
    tasks: backgroundCommands(processes, transcript, listed).filter((command) => !served(command, serving)),
  };
}

/// Session Info section a background command opens (App.tsx `openCommands` and
/// `openTrayCommand`): Background tasks while any command runs, a dev server included (its rows head
/// that section), else Subagents (only subagents and started chats run). `running` is the chat's
/// running commands, servers included, as the running line counts them.
export function backgroundSection(running: readonly BackgroundCommand[]): "tasks" | "subagents" {
  return running.length > 0 ? "tasks" : "subagents";
}
