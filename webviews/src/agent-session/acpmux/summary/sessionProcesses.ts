// The chat's background processes from acpmux's registry (cmux-tui/crates/acpmux/docs/
// background-processes.md): `_acpmux/process/list {sessionId}` when the chat opens, then each
// `_acpmux/process_update`. One record per command a harness ran in the background (Claude Code's
// background shells, Codex's background terminals), so the rail's Background tasks card reads the
// same thing for every harness.
import { useEffect, useState } from "react";

export type RailProcess = {
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
function processOf(value: unknown, sessionId: string): RailProcess | undefined {
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
  return index < 0 ? [...processes, process] : processes.with(index, process);
}

/// What the pane's acpmux client offers for them.
export type ProcessSource = {
  listProcesses(sessionId: string): Promise<unknown>;
  /// Registers the `process_update` listener; returns its removal.
  watchProcesses(listener: (process: unknown) => void): () => void;
};

/// Chat `sessionId`'s background processes while `live` (the rail shows), kept current from
/// the registry's updates. A listing that fails leaves what the updates said.
export function useSessionProcesses(
  source: ProcessSource | undefined,
  sessionId: string | undefined,
  live: boolean,
): readonly RailProcess[] {
  const [state, setState] = useState<{ sessionId?: string; processes: readonly RailProcess[] }>({ processes: [] });
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
          processes: known.processes.reduce<readonly RailProcess[]>(
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
