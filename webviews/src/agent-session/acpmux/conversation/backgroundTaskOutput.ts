// What an opened background task note shows beyond its own event (BackgroundTaskNote.tsx): the end
// of what the task printed and, when the harness reported one, its exit code. Both come from
// acpmux's process registry (cmux-tui/crates/acpmux/docs/background-processes.md):
// `_acpmux/process/list {sessionId}` finds the process the note's tool call started, and
// `_acpmux/process/tail` reads the end of its output file. Live previews poll only while their row
// is expanded; closing, unmounting, or the row leaving the live list stops and cleans up the timer.
// The registry serves only this Mac's clients and keeps output for Claude Code's shells only.
import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { visibleInterval } from "../../../ui/pageClock";
import { stripAnsi } from "./toolOutputModel";

/// How much of the end of a task's output an opened note reads.
export const BACKGROUND_TAIL_BYTES = 16 * 1024;

export type BackgroundTaskOutput = {
  /// The end of what the task printed (colour codes kept; ShellBlock strips them), when known.
  output?: string;
  /// Whether `output` starts after the beginning of what it printed.
  cut?: boolean;
  exitCode?: number;
  running?: boolean;
  /// acpmux keeps no output for this process (a Codex one): nothing to show is not "nothing printed".
  unavailable?: boolean;
  /// The read failed (the daemon did not answer): nothing is known yet, so an open reads again.
  unread?: boolean;
};

/// The bounded view shown in an expanded tray row. Keeping this at the render edge means a
/// completed process can retain its full tail in the reader without growing the row indefinitely.
export function tailLines(output: string | undefined, maxLines = 10): string | undefined {
  if (!output || maxLines <= 0) return undefined;
  const lines = stripAnsi(output).replace(/\r\n/g, "\n").split("\n");
  while (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines.slice(-maxLines).join("\n");
}

/// What the pane's acpmux client offers for a chat's background processes.
export type BackgroundTaskOutputSource = {
  listProcesses(sessionId: string): Promise<unknown>;
  tailProcess(processId: string, maxBytes: number): Promise<unknown>;
};

/// The source and the chat it reads for; none outside the app's pane (tests, the gallery's preview).
export type BackgroundTaskOutputReader = { source: BackgroundTaskOutputSource; sessionId: string };

export const BackgroundTaskOutputContext = createContext<BackgroundTaskOutputReader | undefined>(undefined);

/// The registry's record for the process tool call `toolCallId` started, from a `process/list` reply.
function processFor(
  reply: unknown,
  toolCallId?: string,
  processId?: string,
): { id: string; exitCode?: number; codex: boolean; running: boolean } | undefined {
  const list = (reply as { processes?: unknown } | undefined)?.processes;
  if (!Array.isArray(list)) return undefined;
  // The newest one: an adapter that numbers calls per process can reuse an id (cx-jzhka).
  for (let index = list.length - 1; index >= 0; index -= 1) {
    const raw = (list[index] ?? {}) as Record<string, unknown>;
    const matches =
      processId !== undefined ? raw.id === processId : toolCallId !== undefined && raw.toolCallId === toolCallId;
    if (!matches) continue;
    if (typeof raw.id !== "string" || !raw.id) continue;
    return {
      id: raw.id,
      ...(Number.isInteger(raw.exitCode) ? { exitCode: raw.exitCode as number } : {}),
      codex: raw.harness === "codex",
      running: raw.state === "running",
    };
  }
  return undefined;
}

/// A `process/tail` reply's bytes as text, from the first whole line when the read starts after
/// the file's beginning (its first line may be cut mid-way, a character included).
export function tailText(reply: unknown): { output: string; cut: boolean } | undefined {
  const raw = (reply ?? {}) as { data?: unknown; fromByte?: unknown };
  if (typeof raw.data !== "string") return undefined;
  let text: string;
  try {
    const binary = atob(raw.data);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    text = new TextDecoder().decode(bytes);
  } catch {
    return undefined;
  }
  const cut = typeof raw.fromByte === "number" && raw.fromByte > 0;
  if (cut) {
    const line = text.indexOf("\n");
    text = line < 0 ? text : text.slice(line + 1);
  }
  return { output: text, cut };
}

/// What `reader` knows of the background task tool call `toolCallId` started.
export async function readBackgroundTaskOutput(
  reader: BackgroundTaskOutputReader,
  toolCallId?: string,
  processId?: string,
): Promise<BackgroundTaskOutput> {
  const process = processFor(await reader.source.listProcesses(reader.sessionId), toolCallId, processId);
  if (!process) return {};
  const exit = {
    ...(process.exitCode !== undefined ? { exitCode: process.exitCode } : {}),
    ...(process.running ? { running: true } : {}),
  };
  // acpmux keeps no output for a Codex process yet; it refuses the read.
  if (process.codex) return { ...exit, unavailable: true };
  const tail = tailText(await reader.source.tailProcess(process.id, BACKGROUND_TAIL_BYTES));
  return tail && tail.output ? { ...exit, output: tail.output, cut: tail.cut } : exit;
}

/// Reads of finished tasks, per registry source and chat: a note's output is final once its task
/// ended, so one read serves every open, remount and scroll back. The newest READS_KEPT are kept
/// (memory stays flat however long the chat); a read that failed, or found the process still
/// running (its end not written yet), is dropped once answered so the next ask reads again; either
/// answer leaves the note unsettled, so its click asks again.
const READS_KEPT = 128;
type Read = { promise: Promise<BackgroundTaskOutput>; output?: BackgroundTaskOutput };
const reads = new WeakMap<BackgroundTaskOutputSource, Map<string, Read>>();
const readKey = (reader: BackgroundTaskOutputReader, toolCallId: string) => `${reader.sessionId}\u0000${toolCallId}`;

/// The kept read of `toolCallId`'s task, once it answered.
function settledRead(reader: BackgroundTaskOutputReader, toolCallId: string): BackgroundTaskOutput | undefined {
  return reads.get(reader.source)?.get(readKey(reader, toolCallId))?.output;
}

/// Starts reading the finished task `toolCallId` started, unless a read of it is kept or under way,
/// and returns that read. At most one read per task is in flight.
export function prefetchBackgroundTaskOutput(
  reader: BackgroundTaskOutputReader,
  toolCallId: string,
): Promise<BackgroundTaskOutput> {
  let kept = reads.get(reader.source);
  if (!kept) reads.set(reader.source, (kept = new Map()));
  const key = readKey(reader, toolCallId);
  const hit = kept.get(key);
  if (hit) {
    // The newest asked goes last, so the oldest is the one dropped.
    kept.delete(key);
    kept.set(key, hit);
    return hit.promise;
  }
  const read: Read = {
    promise: readBackgroundTaskOutput(reader, toolCallId).then(
      (output) => {
        read.output = output;
        if (output.running && kept.get(key) === read) kept.delete(key);
        return output;
      },
      () => {
        if (kept.get(key) === read) kept.delete(key);
        return (read.output = { unread: true });
      },
    ),
  };
  kept.set(key, read);
  if (kept.size > READS_KEPT) kept.delete(kept.keys().next().value!);
  return read.promise;
}

/// How long a note must stay drawn before it reads its task (a fast scroll past reads nothing).
export const BACKGROUND_PREFETCH_DELAY_MS = 150;

export type BackgroundTaskRead = {
  output: BackgroundTaskOutput;
  /// The read answered (or there is nothing to read: no reader, no tool call): an open draws its
  /// final content now.
  settled: boolean;
  /// Reads now if no read is kept or under way; the read, or undefined when there is nothing to read.
  request: () => Promise<BackgroundTaskOutput> | undefined;
};

/// What the registry knows of a finished task, read ahead of the reader's click: once the note has
/// been drawn for BACKGROUND_PREFETCH_DELAY_MS while `wanted`, or at once on `request` (a hover, a
/// focus, a press). A kept read draws on the first render, so a note opens to its final card in
/// one step (Leo, 2026-11-09: "slow and bad loading state here :(").
export function useBackgroundTaskOutput(toolCallId: string, wanted: boolean): BackgroundTaskRead {
  const reader = useContext(BackgroundTaskOutputContext);
  const key = reader && toolCallId ? readKey(reader, toolCallId) : "";
  const [answered, setAnswered] = useState<{ key: string; output: BackgroundTaskOutput } | undefined>(undefined);
  const kept = reader && toolCallId ? settledRead(reader, toolCallId) : undefined;
  const output = kept ?? (answered?.key === key ? answered.output : undefined);
  const live = useRef(true);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const request = useCallback(() => {
    if (!reader || !toolCallId) return undefined;
    const read = prefetchBackgroundTaskOutput(reader, toolCallId);
    void read.then((value) => {
      if (live.current) setAnswered({ key, output: value });
    });
    return read;
  }, [reader, toolCallId, key]);
  const missing = output === undefined && Boolean(key);
  useEffect(() => {
    if (!wanted || !missing) return;
    const timer = setTimeout(request, BACKGROUND_PREFETCH_DELAY_MS);
    return () => clearTimeout(timer);
  }, [wanted, missing, request]);
  // A read that failed, or found the process still running (the harness said it ended before the
  // registry wrote its exit), is not final: a click reads again rather than opening what it has.
  return {
    output: output ?? {},
    settled: !key || (output !== undefined && !output.running && !output.unread),
    request,
  };
}

/// A tray row's live tail. The caller's `open` is the stop predicate: the effect also stops its
/// clock and ignores late replies when the row closes or unmounts; a hidden page reads nothing.
export function useLiveBackgroundTaskOutput(
  toolCallId: string | undefined,
  processId: string | undefined,
  open: boolean,
): BackgroundTaskOutput {
  const reader = useContext(BackgroundTaskOutputContext);
  const [read, setRead] = useState<{ key: string; output: BackgroundTaskOutput }>();
  const key = reader ? `${reader.sessionId}\u0000${toolCallId ?? ""}\u0000${processId ?? ""}` : "";
  useEffect(() => {
    if (!reader || !open || (!toolCallId && !processId)) return;
    let current = true;
    let reading = false;
    const read = () => {
      if (reading) return;
      reading = true;
      readBackgroundTaskOutput(reader, toolCallId, processId).then(
        (output) => {
          reading = false;
          if (current) setRead({ key, output });
        },
        () => {
          reading = false;
          if (current) setRead({ key, output: {} });
        },
      );
    };
    read();
    // The page clock owns the repeat: no timer while the page is hidden, and the next read comes a
    // full interval after it shows. The row's close or unmount stops it.
    const stop = visibleInterval("background-task-tail", read, 1200);
    return () => {
      current = false;
      stop();
    };
  }, [reader, open, toolCallId, processId, key]);
  return read?.key === key ? read.output : {};
}
