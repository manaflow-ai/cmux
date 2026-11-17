// "Run on a bigger machine" (RunElsewhere.tsx): a chat's slow command runs again on a machine the
// person connected, at the same commit with the same changes, and streams its output back under
// the row. acpmux does the work (`_acpmux/run_elsewhere/plan|start`, cmux-tui
// crates/acpmux/src/run_elsewhere.rs); this module holds what the rows share: when the chip
// shows, the client the rows call, and one small store of each row's run, keyed by tool call, so
// a run's change re-renders only its own row.
import { createContext, useSyncExternalStore } from "react";

/** How long a command runs before the chip offers to move it. */
export const RUN_ELSEWHERE_AFTER_MS = 20_000;

/** One machine acpmux knows: connected and reached by ssh (`ok`), or why not. */
export interface RunMachine {
  name: string;
  ok: boolean;
  why?: string;
}

/** One tracked file the changes carry; `secret` ones stay unless the person sends them. */
export interface RunFile {
  path: string;
  status: string;
  secret: boolean;
}

/** What a run would send (`_acpmux/run_elsewhere/plan`). */
export interface RunPlan {
  eligible: boolean;
  why?: string;
  machines: RunMachine[];
  tree?: {
    /** The repository the other machine fetches, without a login. */
    origin: string;
    base: string;
    prefix: string;
    files: RunFile[];
    untracked: string[];
    untrackedTotal: number;
    patchBytes: number;
    digest: string;
  };
}

/** A background task's output read (`_acpmux/bg/output`). */
export interface RunOutput {
  data: string;
  nextByte: number;
  /** Every byte the task has written so far. */
  totalBytes?: number;
  state: string;
  exitCode?: number | null;
}

/** The daemon calls a run makes; App.tsx binds them to the pane's client and chat. */
export interface RunElsewhereClient {
  plan(command: string): Promise<RunPlan>;
  start(command: string, machine: string, digest: string, sendSecrets: string[]): Promise<{ id: string }>;
  output(taskId: string, fromByte: number): Promise<RunOutput>;
  stop(taskId: string): Promise<unknown>;
}

/** One row's run: choosing (the panel is open), then running and ended. */
export type RunState =
  | { phase: "loading" }
  | { phase: "choosing"; plan: RunPlan; machine?: string; send: string[]; error?: string; starting?: boolean }
  | {
      phase: "running" | "ended";
      machine: string;
      taskId: string;
      output: string;
      /** The next byte of the task's output to read: a row shown again goes on from here. */
      read?: number;
      /** The reads' decoder, holding a character split across two reads while the row is away. */
      decoder?: TextDecoder;
      exitCode?: number | null;
      state?: string;
    };

/** The rows' store: each tool call's run, and a listener set per tool call. */
export class RunElsewhereStore {
  private runs = new Map<string, RunState>();
  private listeners = new Map<string, Set<() => void>>();

  get(toolCallId: string): RunState | undefined {
    return this.runs.get(toolCallId);
  }

  set(toolCallId: string, state: RunState | undefined) {
    if (state) this.runs.set(toolCallId, state);
    else this.runs.delete(toolCallId);
    for (const listener of this.listeners.get(toolCallId) ?? []) listener();
  }

  subscribe(toolCallId: string, listener: () => void): () => void {
    let set = this.listeners.get(toolCallId);
    if (!set) this.listeners.set(toolCallId, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0) this.listeners.delete(toolCallId);
    };
  }
}

export interface RunElsewhere {
  client: RunElsewhereClient;
  store: RunElsewhereStore;
}

/** Absent where nothing can run elsewhere (Quick Chat, a Cloud or remote chat, the gallery's plain rows). */
export const RunElsewhereContext = createContext<RunElsewhere | undefined>(undefined);

const NONE = () => () => undefined;

/** Tool call `toolCallId`'s run, re-read only when it changes. */
export function useRun(runs: RunElsewhere | undefined, toolCallId: string): RunState | undefined {
  const read = () => runs?.store.get(toolCallId);
  // The same read serves a server render (renderToString), which has no store to wait on.
  return useSyncExternalStore(runs ? (listener) => runs.store.subscribe(toolCallId, listener) : NONE, read, read);
}

/** When the chip shows: a shell call with a command line, still running, from `startedAt` +
 * {@link RUN_ELSEWHERE_AFTER_MS}. Undefined when it never does (not a shell, ended, no start). */
export function chipDueAt(tool: {
  kind?: string;
  command?: string;
  startedAt?: number;
  running: boolean;
}): number | undefined {
  if (tool.kind !== "execute" || !tool.command?.trim() || !tool.running || tool.startedAt === undefined)
    return undefined;
  return tool.startedAt + RUN_ELSEWHERE_AFTER_MS;
}

/** The machine a panel picks first: the one chosen last time if it can still take the run, else
 * the first that can. */
export function firstMachine(machines: RunMachine[], last?: string): string | undefined {
  const ok = machines.filter((m) => m.ok);
  return ok.find((m) => m.name === last)?.name ?? ok[0]?.name;
}

/** The most output a run row keeps: its newest bytes, as a terminal's scrollback would. */
export const RUN_OUTPUT_KEEP = 256 * 1024;

/** `output` with `more` appended, trimmed to its newest {@link RUN_OUTPUT_KEEP} characters at a line start. */
export function appendOutput(output: string, more: string): string {
  const next = output + more;
  if (next.length <= RUN_OUTPUT_KEEP) return next;
  const cut = next.length - RUN_OUTPUT_KEEP;
  const line = next.indexOf("\n", cut);
  return next.slice(line < 0 ? cut : line + 1);
}

/** Decode a base64 output chunk as UTF-8 (a split character waits for the next chunk's bytes:
 * the decoder streams). */
export function decodeChunk(decoder: TextDecoder, base64: string): string {
  if (!base64) return "";
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return decoder.decode(bytes, { stream: true });
}

/** The wait before the next output read: short while bytes arrive, backing off to 2 s while the
 * command is quiet, so a long silent build costs a read every 2 s. */
export function nextReadDelay(previous: number, gotBytes: boolean): number {
  if (gotBytes) return 250;
  return Math.min(2000, Math.max(250, previous * 2));
}
