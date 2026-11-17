// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when Session Info shows, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so Session Info's Servers and Background
// tasks read the same thing for every harness. A dev server is told apart by its command, or by the
// page acpmux saw it serve (`preview`: an address its own output printed that accepted a loopback
// connect, hub/processes.rs); cmux-next never scans the machine's processes or ports.
//
// The transcript knows commands too: Claude's background Bash calls, those Ctrl-B moved there
// included (conversation/runInBackground.ts), and their `background_task_update` ends
// (summary/sessionSummary.ts). `backgroundCommands` merges the two into the one list the
// Session Info's Background tasks, the summary card, the running turn's line and the tray above the
// composer (subagents/runningTray.ts) read. The registry wins: a transcript task whose call started a
// listed process is that process.
import { acpmuxSend } from "../conversation/acpmuxSends";
import type { Translate } from "../i18n";
import { useEffect, useRef, useState } from "react";
import type { SummaryBackgroundTask } from "../summary/sessionSummary";
import { replayProcessUpdates } from "./processUpdateReplay";
import { commandWorkLabel } from "./commandWorkLabel";

export type SessionInfoProcess = {
  /// acpmux's id, `<sessionId>/<task id>`: what `_acpmux/process/kill` takes.
  id: string;
  /// The Bash or exec call that started it: the transcript's background task of the same id is
  /// this process (`backgroundCommands`), and its terminal opens by it (processTerminal.ts).
  toolCallId?: string;
  command: string;
  /// What the call that started it says it does (Claude's Bash `description`), as acpmux kept it:
  /// a client that never loaded the call still names the command by it. None from Codex.
  description?: string;
  /// The subagent whose call started it (acpmux's `subagentSessionId`), when a subagent's did.
  subagent?: string;
  /// The workflow agent whose call started it, by Claude's agent id (acpmux's `workflowAgentId`),
  /// when an agent of a workflow did: Session Info lists it under that agent
  /// (summary/workflowView.ts `attributeCommands`).
  workflowAgent?: string;
  /// Unix ms.
  startedAt: number;
  endedAt?: number;
  /// `running`, `exited`, `failed`, `killed` or `lost`.
  state: string;
  /// The page it serves, as acpmux found it: a loopback address its own output printed that
  /// accepted a connect (hub/processes.rs). Only while it runs.
  preview?: ProcessPreview;
};

/// A dev server's page: `http://localhost:5173/` and its port.
export type ProcessPreview = { url: string; port: number };

/// `value` as a page this Mac's preview opens (a loopback http address, URL+AgentPanePreview.swift),
/// else undefined.
function previewOf(value: unknown): ProcessPreview | undefined {
  const raw = (value ?? {}) as Record<string, unknown>;
  const port = raw.port;
  if (typeof raw.url !== "string" || typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65_535)
    return undefined;
  try {
    const url = new URL(raw.url);
    if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
    if (url.hostname !== "localhost" && url.hostname !== "127.0.0.1") return undefined;
    return { url: url.href, port };
  } catch {
    return undefined;
  }
}

/// One wire record for chat `sessionId`, or undefined for another chat's or a malformed one.
function processOf(value: unknown, sessionId: string): SessionInfoProcess | undefined {
  const raw = (value ?? {}) as Record<string, unknown>;
  if (typeof raw.id !== "string" || raw.sessionId !== sessionId) return undefined;
  if (typeof raw.command !== "string" || typeof raw.state !== "string" || typeof raw.startedAt !== "number")
    return undefined;
  const preview = raw.state === "running" ? previewOf(raw.preview) : undefined;
  return {
    id: raw.id,
    ...(typeof raw.toolCallId === "string" && raw.toolCallId ? { toolCallId: raw.toolCallId } : {}),
    command: raw.command,
    ...(typeof raw.description === "string" && raw.description.trim() ? { description: raw.description.trim() } : {}),
    ...(typeof raw.subagentSessionId === "string" && raw.subagentSessionId ? { subagent: raw.subagentSessionId } : {}),
    ...(typeof raw.workflowAgentId === "string" && raw.workflowAgentId ? { workflowAgent: raw.workflowAgentId } : {}),
    startedAt: raw.startedAt,
    ...(typeof raw.endedAt === "number" ? { endedAt: raw.endedAt } : {}),
    state: raw.state,
    ...(preview ? { preview } : {}),
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
  /// With `recent`: the running ones, the `recent` that ended last and those that ended in the last
  /// `endedWithin` ms, the reply saying `recent`, `omitted` and `endedBefore` (direct.ts
  /// `listProcesses`); a reply without `recent` is the whole list.
  listProcesses(sessionId: string, recent?: number, endedWithin?: number): Promise<unknown>;
  /// The processes the tool calls `calls` started, however old (direct.ts `listProcessCalls`).
  /// Without it, or when it fails, the registry holds the whole list.
  listProcessCalls?(sessionId: string, calls: readonly string[]): Promise<readonly unknown[]>;
  /// Registers the `process_update` listener; returns its removal.
  watchProcesses(listener: (process: unknown) => void): () => void;
};

/// What the registry says of a chat: its processes, and whether a `process/list` answered for it
/// (without one, only the updates since the subscription are known). `omitted`: how many of the
/// chat's processes it does not hold (`RegistryWindow`), each one ended and started by no call of
/// the window's `calls`, so a count of the whole history is the held one's plus `omitted`
/// (`backgroundRowCount`). None while it holds the whole list.
export type ProcessRegistry = { processes: readonly SessionInfoProcess[]; listed: boolean; omitted?: number };

const NO_PROCESSES: ProcessRegistry = { processes: [], listed: false };

/// Ended processes a chat's page holds beside every running one while no list of the whole history
/// shows (direct.ts `listProcesses` `recent`, `useProcessRegistry`). Session Info, the summary
/// card's task list and the Background tasks panel read the whole history while they are open.
export const PROCESS_LIST_RECENT = 500;

/// What the registry holds while no list of the chat's whole history shows: every running process,
/// the `PROCESS_LIST_RECENT` that ended last, every one that ended in the last `endedWithin` ms
/// (the tray's linger, App.tsx), and every process the tool calls `calls` started (the
/// transcript's background tasks and a subagent view's calls), read again as `calls` grows.
/// Every process the registry has once held stays held for the chat, so nothing the tray shows
/// goes; `omitted` counts the rest.
export type RegistryWindow = { readonly calls: readonly string[]; readonly endedWithin: number };

type RegistryState = ProcessRegistry & {
  sessionId?: string;
  /// Held under a window: `omitted` and `endedBefore` are the reply's, kept current.
  partial?: boolean;
  /// acpmux's split (`endedBefore`): every ended process not held ended before it.
  endedBefore?: number;
};

/// `record` was one the recent reply left out: it ended before the split (a process ends once, so
/// a new one ends after it).
const leftOut = (record: SessionInfoProcess, endedBefore: number | undefined) =>
  endedBefore !== undefined && record.state !== "running" && (record.endedAt ?? 0) < endedBefore;

/// `records` arrived for chat `state` (updates or a calls read): each replaces its old record or is
/// added last, and one the recent reply left out leaves `omitted`. The same state when nothing changed.
export function arriveProcesses(state: RegistryState, records: readonly SessionInfoProcess[]): RegistryState {
  let processes = state.processes;
  let omitted = state.omitted ?? 0;
  let index: Map<string, number> | undefined;
  for (const record of records) {
    index ??= new Map(processes.map((process, at) => [process.id, at]));
    const at = index.get(record.id);
    if (at !== undefined) {
      if (processes[at] === record) continue;
      processes = processes.map((known, slot) => (slot === at ? record : known));
      continue;
    }
    if (state.partial && leftOut(record, state.endedBefore)) omitted = Math.max(0, omitted - 1);
    index.set(record.id, processes.length);
    processes = [...processes, record];
  }
  if (processes === state.processes) return state;
  return { ...state, processes, ...(state.partial ? { omitted } : {}) };
}

/// The state a recent reply makes: its records, the updates since it was asked (`pending`, newer),
/// then what the chat already held (`held`: every record the registry held stays) and what its
/// calls read (`called`), each once. `omitted` is the reply's less every held record it left out.
export function recentState(
  sessionId: string,
  reply: { processes?: unknown; omitted?: unknown; endedBefore?: unknown },
  pending: ReadonlyMap<string, SessionInfoProcess>,
  held: readonly SessionInfoProcess[],
  called: readonly SessionInfoProcess[],
): RegistryState {
  const listed = processesOf(reply, sessionId);
  const replied = new Set(listed.map((process) => process.id));
  const processes = [...replayProcessUpdates(listed, pending)];
  const have = new Set(processes.map((process) => process.id));
  for (const record of [...held, ...called])
    if (!have.has(record.id)) {
      have.add(record.id);
      processes.push(record);
    }
  const endedBefore = typeof reply.endedBefore === "number" ? reply.endedBefore : undefined;
  let omitted = typeof reply.omitted === "number" ? reply.omitted : 0;
  for (const process of processes) if (!replied.has(process.id) && leftOut(process, endedBefore)) omitted -= 1;
  return {
    sessionId,
    processes,
    listed: true,
    partial: true,
    omitted: Math.max(0, omitted),
    ...(endedBefore === undefined ? {} : { endedBefore }),
  };
}

/// Chat `sessionId`'s background processes while `live`, and while one it knows still runs (so its
/// end arrives), kept current from the registry's updates. A listing that fails leaves what the
/// updates said. Going quiet keeps the last records, and the next listing replaces them, so a
/// count does not drop to zero and back.
///
/// `window`: no list of the whole history shows, so only what it names is read and held
/// (`RegistryWindow`), and a god chat's history stays in acpmux rather than the page's heap.
/// Without it (Session Info, the summary card's tasks or the Background tasks panel shows), every
/// process is read. What the page shows from the registry is the same either way: the tray and the
/// running line read only what the window holds, and a count adds `omitted`. An acpmux or host
/// that cannot read a window is read whole.
export function useProcessRegistry(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
  window?: RegistryWindow,
): ProcessRegistry {
  const [state, setState] = useState<RegistryState>(NO_PROCESSES);
  // A source that could not read a window, for this chat: read whole from then on.
  const [refused, setRefused] = useState<string>();
  const windowed = window !== undefined && source?.listProcessCalls !== undefined && refused !== sessionId;
  const running = state.sessionId === sessionId && state.processes.some((process) => process.state === "running");
  const on = live || running;
  // The window's calls as of now, for a read in flight; and the calls read for the chat so far.
  const calls = useRef<readonly string[]>([]);
  calls.current = window?.calls ?? [];
  const endedWithin = window?.endedWithin;
  const asked = useRef<{ sessionId?: string; calls: Set<string> }>({ calls: new Set() });
  if (asked.current.sessionId !== sessionId || !windowed) asked.current = { sessionId, calls: new Set() };
  // The processes this view saw run, for the chat: the tray may still show one as just ended, so
  // a window read after the whole list keeps it (`recentState` `held`).
  const seenRunning = useRef<{ sessionId?: string; ids: Set<string>; read?: readonly SessionInfoProcess[] }>({
    ids: new Set(),
  });
  if (seenRunning.current.sessionId !== sessionId) seenRunning.current = { sessionId, ids: new Set() };
  // Read once per new list, not per render.
  if (state.sessionId === sessionId && seenRunning.current.read !== state.processes) {
    seenRunning.current.read = state.processes;
    for (const process of state.processes) if (process.state === "running") seenRunning.current.ids.add(process.id);
  }
  useEffect(() => {
    if (!source || !sessionId || !on) return;
    let current = true;
    // This subscription's updates: newer than the list's records.
    // Retain only the latest update per process ID while the list is pending.
    const pending = new Map<string, SessionInfoProcess>();
    let awaitingList = true;
    setState((known) => (known.sessionId === sessionId ? known : { sessionId, processes: [], listed: false }));
    const stop = source.watchProcesses((value) => {
      const process = processOf(value, sessionId);
      if (!process) return;
      if (awaitingList) pending.set(process.id, process);
      setState((known) =>
        known.sessionId === sessionId
          ? arriveProcesses(known, [process])
          : { sessionId, processes: [process], listed: false },
      );
    });
    const settle = () => {
      awaitingList = false;
      pending.clear();
    };
    const whole = (reply: unknown) => {
      const listed = processesOf(reply, sessionId);
      // Buffered updates win over the stale list snapshot.
      const reconciled = replayProcessUpdates(listed, pending);
      settle();
      setState({
        sessionId,
        processes: reconciled,
        // A reply without its list (a daemon that does not keep one) lists nothing.
        listed: Array.isArray((reply as { processes?: unknown } | undefined)?.processes),
      });
    };
    if (!windowed) {
      void source.listProcesses(sessionId).then((reply) => current && whole(reply), settle);
    } else {
      const readCalls = source.listProcessCalls?.bind(source);
      const read = async () => {
        let reply: { processes?: unknown; recent?: unknown; omitted?: unknown; endedBefore?: unknown } | undefined;
        try {
          reply = (await source.listProcesses(sessionId, PROCESS_LIST_RECENT, endedWithin)) as typeof reply;
        } catch {
          return settle();
        }
        if (!current) return;
        // Read whole: an acpmux without `recent` answered its whole list.
        if (reply?.recent !== PROCESS_LIST_RECENT || !readCalls) return whole(reply);
        // The calls the transcript shows, read before the list is shown, so a shell it names is
        // never shown as the transcript's own and then as the registry's.
        const called: SessionInfoProcess[] = [];
        for (let round = 0; round < 8; round += 1) {
          const unasked = calls.current.filter((call) => !asked.current.calls.has(call));
          if (unasked.length === 0) break;
          let records: readonly unknown[];
          try {
            records = await readCalls(sessionId, unasked);
          } catch {
            // A host or acpmux that cannot read `calls`: the whole list, from now on.
            if (current) setRefused(sessionId);
            return;
          }
          if (!current) return;
          for (const call of unasked) asked.current.calls.add(call);
          for (const value of records) {
            const process = processOf(value, sessionId);
            if (process) called.push(process);
          }
        }
        const recent = reply;
        setState((known) => {
          const mine = known.sessionId === sessionId ? known : undefined;
          // After the whole list: only what this view saw run stays beside the window.
          const held = mine?.partial
            ? mine.processes
            : (mine?.processes.filter((process) => seenRunning.current.ids.has(process.id)) ?? []);
          return recentState(sessionId, recent, pending, held, called);
        });
        settle();
      };
      void read();
    }
    return () => {
      current = false;
      settle();
      stop();
    };
    // `calls` and `endedWithin` are read when the list is: a new call is read below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source, sessionId, on, windowed]);
  // Calls the transcript shows that were not read yet (older rows read, a subagent's view opened):
  // their processes, which join what the registry holds.
  const partial = windowed && state.sessionId === sessionId && state.partial === true;
  const shownCalls = window?.calls;
  useEffect(() => {
    if (!partial || !source?.listProcessCalls || !sessionId || !shownCalls) return;
    const unasked = shownCalls.filter((call) => !asked.current.calls.has(call));
    if (unasked.length === 0) return;
    const book = asked.current;
    for (const call of unasked) book.calls.add(call);
    source.listProcessCalls(sessionId, unasked).then(
      (records) => {
        const arrived = records.flatMap((value) => {
          const process = processOf(value, sessionId);
          return process ? [process] : [];
        });
        setState((known) => (known.sessionId === sessionId ? arriveProcesses(known, arrived) : known));
      },
      () => {
        for (const call of unasked) book.calls.delete(call);
        setRefused(sessionId);
      },
    );
  }, [partial, source, sessionId, shownCalls]);
  if (state.sessionId !== sessionId) return NO_PROCESSES;
  // The whole list read after a window: no count is added.
  return state;
}

/// How many rows Session Info's Background tasks lists for these processes and transcript tasks
/// (`sessionInfoLists`: the running servers and every other command), with the `omitted`
/// processes the registry does not hold (`ProcessRegistry.omitted`): each ended, started by no
/// transcript task's call, so each one row. The whole history's count, whatever the registry holds.
export function backgroundRowCount(
  processes: readonly SessionInfoProcess[],
  transcript: readonly SummaryBackgroundTask[],
  listed: boolean,
  omitted = 0,
): number {
  const { servers, tasks } = sessionInfoLists(processes, transcript, listed);
  return servers.length + tasks.length + omitted;
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
  /// The subagent whose call started it, from the registry: the tray names it on the line.
  subagent?: string;
  /// The workflow agent whose call started it, from the registry (Claude's agent id).
  workflowAgent?: string;
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
  /// The page it serves, from the registry (`SessionInfoProcess.preview`).
  preview?: ProcessPreview;
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
      : process.description
        ? { description: process.description }
        : {}),
    ...(process.subagent ? { subagent: process.subagent } : {}),
    ...(process.workflowAgent ? { workflowAgent: process.workflowAgent } : {}),
    state: PROCESS_STATE[process.state] ?? "stopped",
    processId: process.id,
    startedAt: process.startedAt,
    ...(process.toolCallId ? { toolCallId: process.toolCallId } : {}),
    ...(process.endedAt !== undefined ? { endedAt: process.endedAt } : {}),
    ...(process.preview ? { preview: process.preview } : {}),
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
  const work = commandWorkLabel(text);
  if (work) return work;
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

/// Whether `command` serves something, as `serverOf` tells a server: a server command, or one that
/// names a port.
export const servesCommand = (command: string): boolean =>
  SERVER_COMMAND.test(command) || PORTS.some((pattern) => command.match(pattern) !== null);

export type SessionInfoServer = SessionInfoProcess & {
  /// The port acpmux saw it serve first (`preview`), then the ports the command names, in the order
  /// named; empty when it knows none (the default port is never guessed).
  readonly ports: readonly number[];
};

/// `process` as a server, or undefined for any other background command. A process acpmux saw
/// serve a page is one whatever its command.
export function serverOf(process: SessionInfoProcess): SessionInfoServer | undefined {
  const command = process.command;
  const server = SERVER_COMMAND.test(command) || process.preview !== undefined;
  const ports = new Set<number>(process.preview ? [process.preview.port] : []);
  for (const pattern of server ? [...PORTS, SHORT_PORT] : PORTS)
    for (const match of command.matchAll(pattern)) {
      const port = Number(match[1]);
      if (port > 0 && port < 65536) ports.add(port);
    }
  if (!server && ports.size === 0) return undefined;
  return { ...process, ports: [...ports] };
}

/// The address `port` of `server` opens: the page acpmux saw it serve when that is the port (its
/// scheme and path kept), else the port on localhost.
export function serverUrl(server: SessionInfoServer, port: number): string {
  return server.preview?.port === port ? server.preview.url : `http://localhost:${port}`;
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
