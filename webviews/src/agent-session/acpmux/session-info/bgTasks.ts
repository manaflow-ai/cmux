// The chat's daemon-owned background tasks (`acpmux bg start`, the `acpmux` MCP server's
// `bg_start`; cmux-tui/crates/acpmux/src/hub/bg_tasks.rs) as records of the chat's process registry
// (processes.ts), so everything that shows the registry's commands shows them too: the running tray
// above the composer with each one's command, elapsed time, output and Stop
// (subagents/runningTray.ts), the turn's counts, Session Info and the Background tasks panel.
// Issue #45951: an agent said it ran two watchers, and the chat showed nothing of them until a
// "Background task finished" row.
//
// They are not the harness's shells: acpmux runs them under its own runner, lists them with
// `_acpmux/bg/list`, reads them with `_acpmux/bg/output`, stops them with `_acpmux/bg/stop` and says
// when one starts or ends with `_acpmux/bg_update {task}`. Their process id names that apart:
// `<sessionId>/bg:<task id>` (direct.ts routes a tail and a stop by it).
import { useEffect, useState } from "react";

/// What a task's process id carries after its chat's id.
const MARK = "/bg:";

/// The most ended tasks a listing passes on: a chat keeps every task it ever ran.
export const BG_ENDED_KEPT = 20;

/// Task `taskId` of chat `sessionId` as a registry process id.
export const bgProcessId = (sessionId: string, taskId: string): string => `${sessionId}${MARK}${taskId}`;

/// The chat and task a registry process id names, when it names a daemon task.
export function bgTaskOf(processId: string): { sessionId: string; taskId: string } | undefined {
  const at = processId.indexOf(MARK);
  if (at <= 0) return undefined;
  const taskId = processId.slice(at + MARK.length);
  return taskId ? { sessionId: processId.slice(0, at), taskId } : undefined;
}

/// A `bg/list` entry's state as a registry one: an exit that failed is `failed`, a stop or a
/// signal `killed`, a runner that vanished `lost`.
function stateOf(raw: Record<string, unknown>): string | undefined {
  switch (raw.state) {
    case "running":
      return "running";
    case "exited":
      return raw.exitCode === 0 ? "exited" : "failed";
    case "stopped":
    case "killed":
      return "killed";
    case "lost":
      return "lost";
    default:
      return undefined;
  }
}

/// One `bg/list` entry or `bg_update` task as a `process/list` record (processes.ts `processOf`
/// reads it), or undefined for a malformed one.
export function bgTaskProcess(value: unknown): Record<string, unknown> | undefined {
  const raw = (value ?? {}) as Record<string, unknown>;
  if (typeof raw.id !== "string" || !raw.id || typeof raw.sessionId !== "string" || !raw.sessionId) return undefined;
  if (typeof raw.command !== "string" || typeof raw.startedAt !== "number") return undefined;
  const state = stateOf(raw);
  if (!state) return undefined;
  const description = typeof raw.description === "string" ? raw.description.trim() : "";
  return {
    id: bgProcessId(raw.sessionId, raw.id),
    sessionId: raw.sessionId,
    command: raw.command,
    ...(description ? { description } : {}),
    state,
    startedAt: raw.startedAt,
    ...(typeof raw.endedAt === "number" ? { endedAt: raw.endedAt } : {}),
    ...(Number.isInteger(raw.exitCode) ? { exitCode: raw.exitCode } : {}),
    harness: "acpmux",
    origin: "acpmux_bg",
  };
}

/// A `bg/list` reply's tasks as registry records: every running one, and the latest ended ones
/// (at most `BG_ENDED_KEPT`), in the order they started.
export function bgTaskProcesses(reply: unknown): Record<string, unknown>[] {
  const list = (reply as { tasks?: unknown } | undefined)?.tasks;
  const records = (Array.isArray(list) ? list : []).flatMap((value) => {
    const record = bgTaskProcess(value);
    return record ? [record] : [];
  });
  records.sort((a, b) => (a.startedAt as number) - (b.startedAt as number));
  const ended = records.filter((record) => record.state !== "running");
  const dropped = new Set(ended.slice(0, Math.max(0, ended.length - BG_ENDED_KEPT)));
  return records.filter((record) => !dropped.has(record));
}

/// What the pane's acpmux client offers for a chat's daemon tasks (direct.ts).
export type BgTaskSource = {
  listBgTasks(sessionId: string): Promise<unknown>;
  /// Registers the `bg_update` listener; returns its removal.
  watchBgTasks(listener: (task: unknown) => void): () => void;
};

/// Whether a daemon task of chat `sessionId` runs: one listing when the chat shows, then its
/// `bg_update`s. The pane keeps the process registry live while it does, so a chat opened while
/// its watcher runs shows it with no turn running (App.tsx `useProcessRegistry`).
export function useBgTasksRunning(source: BgTaskSource | undefined, sessionId: string | undefined): boolean {
  const [running, setRunning] = useState<{ sessionId?: string; ids: ReadonlySet<string> }>({ ids: new Set() });
  useEffect(() => {
    if (!source || !sessionId) return;
    let current = true;
    const update = (record: Record<string, unknown> | undefined) => {
      if (!record || record.sessionId !== sessionId) return;
      const id = record.id as string;
      setRunning((known) => {
        const ids = new Set(known.sessionId === sessionId ? known.ids : []);
        if (record.state === "running") ids.add(id);
        else if (!ids.delete(id)) return known;
        return { sessionId, ids };
      });
    };
    const stop = source.watchBgTasks((task) => update(bgTaskProcess(task)));
    source.listBgTasks(sessionId).then(
      (reply) => {
        if (!current) return;
        const ids = new Set(
          bgTaskProcesses(reply)
            .filter((record) => record.state === "running")
            .map((record) => record.id as string),
        );
        setRunning((known) =>
          known.sessionId === sessionId ? { sessionId, ids: new Set([...known.ids, ...ids]) } : { sessionId, ids },
        );
      },
      // A daemon without the methods, or a connection they are not served to (a remote one).
      () => undefined,
    );
    return () => {
      current = false;
      stop();
    };
  }, [source, sessionId]);
  return running.sessionId === sessionId && running.ids.size > 0;
}
