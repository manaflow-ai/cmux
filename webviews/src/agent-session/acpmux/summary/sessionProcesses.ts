// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when the chat opens, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so the rail's Background tasks card reads the
// same thing for every harness.
import { useEffect, useState } from "react";

export type RailProcess = {
  /// acpmux's id, `<sessionId>/<task id>`: what `_acpmux/process/kill` takes.
  id: string;
  /// The Bash or exec call that started it: the transcript's background task of the same id is
  /// this process (summary/backgroundWork.ts), and its terminal opens by it (processTerminal.ts).
  toolCallId?: string;
  command: string;
  /// Unix ms.
  startedAt: number;
  endedAt?: number;
  /// `running`, `exited`, `failed`, `killed` or `lost`.
  state: string;
};

/// One wire record for chat `sessionId`, or undefined for another chat's or a malformed one.
function processOf(value: unknown, sessionId: string): RailProcess | undefined {
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
export function processesOf(reply: unknown, sessionId: string): RailProcess[] {
  const list = (reply as { processes?: unknown } | undefined)?.processes;
  return (Array.isArray(list) ? list : []).flatMap((value) => {
    const process = processOf(value, sessionId);
    return process ? [process] : [];
  });
}

/// `processes` with a `process_update`'s record in place of its old one, or added last; the same
/// array when the record is another chat's.
export function mergeProcess(
  processes: readonly RailProcess[],
  value: unknown,
  sessionId: string,
): readonly RailProcess[] {
  const process = processOf(value, sessionId);
  if (!process) return processes;
  const index = processes.findIndex((known) => known.id === process.id);
  return index < 0 ? [...processes, process] : processes.map((known, i) => (i === index ? process : known));
}

/// What the pane's acpmux client offers for them.
export type ProcessSource = {
  listProcesses(sessionId: string): Promise<unknown>;
  /// Registers the `process_update` listener; returns its removal.
  watchProcesses(listener: (process: unknown) => void): () => void;
};

/// What the registry says of a chat: its processes, and whether a `process/list` answered for it
/// (without one, only the updates since the subscription are known).
export type ProcessRegistry = { processes: readonly RailProcess[]; listed: boolean };

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
    let updates: readonly RailProcess[] = [];
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
          processes: updates.reduce<readonly RailProcess[]>(
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

/// Chat `sessionId`'s background processes while `live` (the rail shows), kept current from
/// the registry's updates. A listing that fails leaves what the updates said.
export function useSessionProcesses(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): readonly RailProcess[] {
  return useProcessRegistry(source, sessionId, live).processes;
}
