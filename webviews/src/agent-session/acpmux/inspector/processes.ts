// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when the Inspector shows, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so the Inspector's Servers and Background
// tasks read the same thing for every harness. A dev server is told apart by its command alone
// (`serverOf`): cmux-next never scans processes or ports.
import { useEffect, useState } from "react";

export type InspectorProcess = {
  /// acpmux's id, `<sessionId>/<task id>`: what `_acpmux/process/kill` takes.
  id: string;
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

/// Chat `sessionId`'s background processes while `live` (the Inspector shows), kept current from
/// the registry's updates. A listing that fails leaves what the updates said.
export function useInspectorProcesses(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): readonly InspectorProcess[] {
  const [state, setState] = useState<{ sessionId?: string; processes: readonly InspectorProcess[] }>({ processes: [] });
  useEffect(() => {
    if (!source || !sessionId || !live) return;
    let current = true;
    setState({ sessionId, processes: [] });
    const stop = source.watchProcesses((value) =>
      setState((known) => ({ sessionId, processes: mergeProcess(known.processes, value, sessionId) })),
    );
    source.listProcesses(sessionId).then(
      (reply) => {
        if (!current) return;
        const listed = processesOf(reply, sessionId);
        // An update that arrived while the list was on its way is newer than the list's record.
        setState((known) => ({
          sessionId,
          processes: known.processes.reduce<readonly InspectorProcess[]>(
            (all, process) => mergeProcess(all, { ...process, sessionId }, sessionId),
            listed,
          ),
        }));
      },
      () => undefined,
    );
    return () => {
      current = false;
      stop();
    };
  }, [source, sessionId, live]);
  return state.sessionId === sessionId ? state.processes : [];
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
