// What a background turn's line opens to when it has no rows of its own to show (Leo, 2026-11-21:
// "background tasks not expandable. even if they're denoting completion, why shouldn't they get the
// same treatment?"). The line "Background task finished: bg-53568892f4dd" named a task and opened
// nothing: in the default look its turn's rows already draw where they ran
// (backgroundTurnLook.experiment.ts), so the line had no rows to fold. It now opens as a command row
// opens, to the task itself: its command, how it ended and the last lines it printed.
//
// A Claude Code shell's end comes whole with the turn: acpmux builds its command, exit and the end
// of its output when the turn starts (`cause.command`, hub/command_end.rs), so the line opens to it
// with no read, and keeps it after the output file is gone (Leo, 2026-11-24, on a card that showed
// only "Finished": "but i couldnt... do anything?"). Otherwise, from what the line already has (the
// turn's cause and source, direct.ts `backgroundSource`) and what it can read: an acpmux task named by its `bg-…` id (`_acpmux/bg/output`, its record and the end of
// its output), else the process the turn's starting call ran (`_acpmux/process/list` and `tail`,
// backgroundTaskOutput.ts). One read per task, kept, so an open, a remount and a scroll back read once.
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import type { AcpmuxBackgroundTurn, AcpmuxCommandEnd } from "../model";
import { commandEndShows } from "./commandEnd";
import {
  BACKGROUND_TAIL_BYTES,
  BackgroundTaskOutputContext,
  prefetchBackgroundTaskOutput,
  tailLines,
  tailText,
  type BackgroundTaskOutputReader,
  type BackgroundTaskOutputSource,
} from "./backgroundTaskOutput";

/// An acpmux background task's id as its notices name it ("Background task finished: bg-5356…").
const TASK_ID = /\bbg-[0-9a-f]{6,}\b/i;

/// The `bg-…` task a turn answered, from its notice's own words or its line's label.
export function backgroundTurnTaskId(turn: AcpmuxBackgroundTurn, label?: string): string | undefined {
  for (const text of [turn.cause?.summary, label, turn.reason, turn.source?.command])
    if (text) {
      const match = TASK_ID.exec(text);
      if (match) return match[0];
    }
  return undefined;
}

/// What an opened line shows: the command as typed, how it ended, and the end of its output.
export type BackgroundTurnTask = {
  command?: string;
  description?: string;
  /// The task's end: `exited`, `failed`, `stopped`, `killed`, `lost`, or the notice's own status.
  state?: string;
  exitCode?: number;
  output?: string;
  /// `output` starts after the beginning of what the task printed.
  cut?: boolean;
  /// Milliseconds it ran, when its record has both ends.
  tookMs?: number;
  /// Whether its output is there (acpmux's `outputState`, hub/command_end.rs), when acpmux said.
  outputState?: AcpmuxCommandEnd["outputState"];
};

/// Whether a line has something to open to: a task it can name or read.
export function backgroundTurnOpensTask(turn: AcpmuxBackgroundTurn, label?: string): boolean {
  if (turn.running) return false;
  // acpmux said what it ran: it opens when that has anything to show.
  const end = turn.cause?.command;
  if (end) return commandEndShows(end);
  return Boolean(backgroundTurnTaskId(turn, label) || turn.cause?.origin || turn.source?.command);
}

/// What the line knows without a read: acpmux's own account of the command (`cause.command`), else
/// its source's command and its notice's status.
export function backgroundTurnTaskKnown(turn: AcpmuxBackgroundTurn): BackgroundTurnTask {
  const end = turn.cause?.command;
  if (end)
    return {
      ...((end.command || turn.source?.command) && { command: end.command || turn.source?.command }),
      ...(end.description && { description: end.description }),
      state: end.state || turn.cause!.status,
      ...(end.exitCode !== undefined && { exitCode: end.exitCode }),
      ...(end.output && { output: end.output, cut: end.cut === true }),
      outputState: end.outputState,
    };
  return {
    ...(turn.source?.command && { command: turn.source.command }),
    ...(turn.cause?.status && { state: turn.cause.status }),
  };
}

/// One `_acpmux/bg/output` reply as what a line shows.
export function taskFromBgOutput(reply: unknown): BackgroundTurnTask {
  const raw = (reply ?? {}) as Record<string, unknown>;
  // Its bytes (`data`), else the text acpmux decoded for it (`text`, then the record's `tail`).
  const plain = typeof raw.text === "string" ? raw.text : typeof raw.tail === "string" ? raw.tail : undefined;
  const text =
    tailText(reply) ??
    (plain ? { output: plain, cut: typeof raw.fromByte === "number" && raw.fromByte > 0 } : undefined);
  const said = STATES.find((known) => known === raw.outputState);
  // acpmux's word on its output, else what the reply shows: bytes or text read (none: it printed nothing).
  const outputState = said ?? (text?.output ? "printed" : "data" in raw || plain !== undefined ? "empty" : undefined);
  const started = typeof raw.startedAt === "number" ? raw.startedAt : undefined;
  const ended = typeof raw.endedAt === "number" ? raw.endedAt : undefined;
  return {
    ...(typeof raw.command === "string" && raw.command && { command: raw.command }),
    ...(typeof raw.description === "string" && raw.description && { description: raw.description }),
    ...(typeof raw.state === "string" && { state: raw.state }),
    ...(Number.isInteger(raw.exitCode) && { exitCode: raw.exitCode as number }),
    ...(text?.output && { output: text.output, cut: text.cut }),
    ...(outputState && { outputState }),
    ...(started !== undefined && ended !== undefined && ended >= started && { tookMs: ended - started }),
  };
}

const STATES = ["printed", "empty", "gone"] as const;

const READS_KEPT = 128;
const reads = new WeakMap<BackgroundTaskOutputSource, Map<string, Promise<BackgroundTurnTask>>>();

/// Reads the task a line names, once per chat and task (the newest READS_KEPT kept).
export function readBackgroundTurnTask(
  reader: BackgroundTaskOutputReader,
  turn: AcpmuxBackgroundTurn,
  label?: string,
): Promise<BackgroundTurnTask> | undefined {
  const id = backgroundTurnTaskId(turn, label);
  // acpmux sent the command's end with the turn: there is nothing more to read.
  const origin = turn.cause?.command ? undefined : turn.cause?.origin;
  const key = `${reader.sessionId}\u0000${id ?? origin ?? ""}`;
  if (!id && !origin) return undefined;
  let kept = reads.get(reader.source);
  if (!kept) reads.set(reader.source, (kept = new Map()));
  const hit = kept.get(key);
  if (hit) return hit;
  const known = backgroundTurnTaskKnown(turn);
  const tailTask = reader.source.tailTask;
  const read: Promise<BackgroundTurnTask> =
    id && tailTask
      ? tailTask(id, BACKGROUND_TAIL_BYTES).then((reply) => ({ ...known, ...taskFromBgOutput(reply) }))
      : prefetchBackgroundTaskOutput(reader, origin!).then((output) => ({
          ...known,
          ...(output.end?.command && { command: output.end.command }),
          ...(output.end?.description && { description: output.end.description }),
          ...(output.end?.state && { state: output.end.state }),
          ...(output.end?.outputState && { outputState: output.end.outputState }),
          ...(output.exitCode !== undefined && { exitCode: output.exitCode }),
          ...(output.output && { output: output.output, cut: output.cut }),
        }));
  // No answer: acpmux no longer has the task (a restart, another machine's chat), so its output is
  // not to be had; the card says so rather than drawing an empty box.
  const settled = read.catch(() => {
    kept.delete(key);
    return { ...known, outputState: known.outputState ?? ("gone" as const) };
  });
  kept.set(key, settled);
  if (kept.size > READS_KEPT) kept.delete(kept.keys().next().value!);
  return settled;
}

/// The task a line names: what it knows at once, then the read once it answers. `request` starts the
/// read (a hover, a focus, a press) and resolves when it has answered.
export function useBackgroundTurnTask(
  turn: AcpmuxBackgroundTurn,
  label: string | undefined,
  wanted: boolean,
): { task: BackgroundTurnTask; settled: boolean; request: () => Promise<BackgroundTurnTask> | undefined } {
  const reader = useContext(BackgroundTaskOutputContext);
  const [read, setRead] = useState<BackgroundTurnTask | undefined>(undefined);
  const live = useRef(true);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const request = useCallback(() => {
    if (!reader) return undefined;
    const pending = readBackgroundTurnTask(reader, turn, label);
    void pending?.then((task) => {
      if (live.current) setRead(task);
    });
    return pending;
  }, [reader, turn, label]);
  useEffect(() => {
    if (wanted && read === undefined) void request();
  }, [wanted, read, request]);
  return {
    task: read ?? backgroundTurnTaskKnown(turn),
    settled: read !== undefined || !reader || Boolean(turn.cause?.command && !backgroundTurnTaskId(turn, label)),
    request,
  };
}

/// How many printed lines an opened line shows: the end of the output, all of it in sight. The card
/// holds eight lines before it scrolls (conversation.css `.cv-shell__body[data-preview="cut"]`) and
/// only a live one follows its end, so a finished task's tail fits under the cut mark unscrolled.
export const BACKGROUND_TURN_TAIL_LINES = 7;

/// What the opened line's command card draws: the command, the last lines, the exit when it failed
/// (ShellBlock draws a non-zero one) and, otherwise, how it ended in a word (`ended`, a state key).
export function backgroundTurnTaskCard(task: BackgroundTurnTask): {
  command?: string;
  description?: string;
  output?: string;
  cut: boolean;
  exitCode?: number;
  ended?: "completed" | "failed" | "stopped";
  /// The command's end as the shared card draws it (CommandEndCard.tsx).
  end: Partial<AcpmuxCommandEnd>;
} {
  const whole = task.output?.replace(/\n$/, "");
  const output = tailLines(whole, BACKGROUND_TURN_TAIL_LINES);
  const failed = task.exitCode !== undefined && task.exitCode !== 0;
  const ended =
    task.state === "exited" || task.state === "completed"
      ? "completed"
      : task.state === "failed" || task.state === "lost"
        ? "failed"
        : task.state === "stopped" || task.state === "killed"
          ? "stopped"
          : undefined;
  const cut = Boolean(task.cut || (output !== undefined && output !== whole));
  // How it stands, in acpmux's words for a command's end (hub/command_end.rs `state_word`).
  const state = task.state === "running" ? "running" : task.state === "lost" ? "lost" : ended;
  const end: Partial<AcpmuxCommandEnd> = {
    ...(task.command && { command: task.command }),
    ...(state && { state }),
    ...(task.exitCode !== undefined && { exitCode: task.exitCode }),
    ...(output && { output, cut }),
    ...((task.outputState ?? (output ? "printed" : undefined)) && {
      outputState: task.outputState ?? "printed",
    }),
  };
  return {
    ...(task.command && { command: task.command }),
    ...(task.description && { description: task.description }),
    ...(output && { output }),
    cut,
    ...(task.exitCode !== undefined && { exitCode: task.exitCode }),
    ...(ended && !failed && { ended }),
    end,
  };
}
