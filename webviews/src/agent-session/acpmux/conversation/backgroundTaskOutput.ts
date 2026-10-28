// What an opened background task note shows beyond its own event (BackgroundTaskNote.tsx): the end
// of what the task printed and, when the harness reported one, its exit code. Both come from
// acpmux's process registry (cmux-tui/crates/acpmux/docs/background-processes.md):
// `_acpmux/process/list {sessionId}` finds the process the note's tool call started, and
// `_acpmux/process/tail` reads the end of its output file. Live previews poll only while their row
// is expanded; closing, unmounting, or the row leaving the live list stops and cleans up the timer.
// The registry serves only this Mac's clients and keeps output for Claude Code's shells only.
import { createContext, useContext, useEffect, useState } from "react";
import { stripAnsi } from "./toolOutput";

/// How much of the end of a task's output an opened note reads.
export const BACKGROUND_TAIL_BYTES = 16 * 1024;

export type BackgroundTaskOutput = {
  /// The end of what the task printed (colour codes kept; ShellBlock strips them), when known.
  output?: string;
  /// Whether `output` starts after the beginning of what it printed.
  cut?: boolean;
  exitCode?: number;
  running?: boolean;
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

/// A tray row's live tail. The caller's `open` is the stop predicate: the effect also cleans up
/// its timer and ignores late replies when the row closes or unmounts.
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
    let timer: ReturnType<typeof setTimeout> | undefined;
    let poll: () => void;
    const schedule = () => {
      timer = setTimeout(poll, 1200);
    };
    poll = () => {
      readBackgroundTaskOutput(reader, toolCallId, processId).then(
        (output) => {
          if (!current) return;
          setRead({ key, output });
          // The row is live while mounted; its unmount/close clears this timer and stops polling.
          schedule();
        },
        () => {
          if (!current) return;
          setRead({ key, output: {} });
          schedule();
        },
      );
    };
    poll();
    return () => {
      current = false;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [reader, open, toolCallId, processId, key]);
  return read?.key === key ? read.output : {};
}
