// What an opened background task note shows beyond its own event (BackgroundTaskNote.tsx): the end
// of what the task printed and, when the harness reported one, its exit code. Both come from
// acpmux's process registry (cmux-tui/crates/acpmux/docs/background-processes.md):
// `_acpmux/process/list {sessionId}` finds the process the note's tool call started, and
// `_acpmux/process/tail` reads the end of its output file. Live previews poll only while their row
// is expanded and the page is shown (startPageInterval, as Blink stops a hidden page's timers in
// page_scheduler_impl.cc), and stop once the process has exited; closing, unmounting, or the row
// leaving the live list stops and cleans up the timer. Showing the page again reads nothing: the
// next read waits for its period. The registry serves only this Mac's clients and keeps output for
// Claude Code's shells only.
import { createContext, useContext, useEffect, useState } from "react";
import {
  type PageIntervalOptions,
  pageIsActive,
  pageLifecycleFor,
  startPageInterval,
} from "../../../pages/shared/pageLifecycle";
import { stripAnsi } from "./toolOutput";

/// How much of the end of a task's output an opened note reads.
export const BACKGROUND_TAIL_BYTES = 16 * 1024;

/// How often an expanded tray row reads its running task's tail while the page is shown.
export const BACKGROUND_TAIL_POLL_MS = 1200;

export type BackgroundTaskOutput = {
  /// The end of what the task printed (colour codes kept; ShellBlock strips them), when known.
  output?: string;
  /// Whether `output` starts after the beginning of what it printed.
  cut?: boolean;
  exitCode?: number;
  running?: boolean;
  /// The registry lists the process and it no longer runs (exited, failed, killed or lost), so its
  /// output is final. A lost process, and a killed or failed one, can end with no exit code.
  ended?: boolean;
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
    ...(process.running ? { running: true } : { ended: true }),
  };
  // acpmux keeps no output for a Codex process yet; it refuses the read.
  if (process.codex) return exit;
  const tail = tailText(await reader.source.tailProcess(process.id, BACKGROUND_TAIL_BYTES));
  return tail && tail.output ? { ...exit, output: tail.output, cut: tail.cut } : exit;
}

/// What the registry knows of the task, read once `open` first turns true; empty until it answers
/// and when it cannot (no reader, not listed, a refused read).
export function useBackgroundTaskOutput(toolCallId: string, open: boolean): BackgroundTaskOutput {
  const reader = useContext(BackgroundTaskOutputContext);
  const [read, setRead] = useState<{ key: string; output: BackgroundTaskOutput } | undefined>(undefined);
  const key = reader ? `${reader.sessionId}\u0000${toolCallId}` : "";
  const wanted = open && Boolean(reader) && Boolean(toolCallId) && read?.key !== key;
  useEffect(() => {
    if (!wanted || !reader) return;
    let current = true;
    readBackgroundTaskOutput(reader, toolCallId).then(
      (output) => {
        if (current) setRead({ key, output });
      },
      () => {
        if (current) setRead({ key, output: {} });
      },
    );
    return () => {
      current = false;
    };
  }, [wanted, reader, toolCallId, key]);
  return read?.key === key ? read.output : {};
}

/// Reads the task's tail now if the page is shown, then every `BACKGROUND_TAIL_POLL_MS` while it
/// is shown, one read at a time, until the registry lists the process as no longer running (its
/// output is then final, with or without an exit code) or the returned stop runs. A hidden or frozen page arms no timer. `onRead` gets each
/// answer, `{}` for a refused read; nothing after the stop.
export function pollBackgroundTaskOutput(
  reader: BackgroundTaskOutputReader,
  toolCallId: string | undefined,
  processId: string | undefined,
  onRead: (output: BackgroundTaskOutput) => void,
  options: PageIntervalOptions = {},
): () => void {
  const lifecycle = options.lifecycle ?? pageLifecycleFor();
  let current = true;
  let reading = false;
  let stopInterval = () => {};
  const stop = () => {
    current = false;
    stopInterval();
  };
  const read = () => {
    if (reading) return;
    reading = true;
    readBackgroundTaskOutput(reader, toolCallId, processId).then(
      (output) => {
        reading = false;
        if (!current) return;
        onRead(output);
        if (output.ended) stop();
      },
      () => {
        reading = false;
        if (current) onRead({});
      },
    );
  };
  if (pageIsActive(lifecycle)) read();
  stopInterval = startPageInterval(read, BACKGROUND_TAIL_POLL_MS, { lifecycle, timers: options.timers });
  return stop;
}

/// A tray row's live tail. The caller's `open` is the stop predicate: the effect also cleans up
/// its timer and ignores late replies when the row closes or unmounts. `options` is the page's
/// lifecycle and timers (a fake in tests).
export function useLiveBackgroundTaskOutput(
  toolCallId: string | undefined,
  processId: string | undefined,
  open: boolean,
  options: PageIntervalOptions = {},
): BackgroundTaskOutput {
  const reader = useContext(BackgroundTaskOutputContext);
  const [read, setRead] = useState<{ key: string; output: BackgroundTaskOutput }>();
  const key = reader ? `${reader.sessionId}\u0000${toolCallId ?? ""}\u0000${processId ?? ""}` : "";
  const { lifecycle, timers } = options;
  useEffect(() => {
    if (!reader || !open || (!toolCallId && !processId)) return;
    return pollBackgroundTaskOutput(reader, toolCallId, processId, (output) => setRead({ key, output }), {
      lifecycle,
      timers,
    });
  }, [reader, open, toolCallId, processId, key, lifecycle, timers]);
  return read?.key === key ? read.output : {};
}
