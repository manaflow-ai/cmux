// Session replay's clock (ReplayScreen.tsx). Playback runs on replay time: the recorded wall clock
// with every quiet gap longer than IDLE_GAP_MS shortened to it, so a chat left open overnight
// still plays through in the time its work took.
import { mergeToolItem, type EventRecord } from "../direct";
import type { AcpmuxActivity } from "../model";
import { editedPaths } from "../toolPaths";

/// The longest pause replay keeps between two recorded events.
export const IDLE_GAP_MS = 2_000;

/** A tool call's start on the timeline: where jump to previous/next tool call lands. */
export type ReplayMark = { seq: number; time: number; label: string };

/** A file a tool call read or edited, or a command it ran, at the call's start (the replay's
 * Files and Commands list). */
export type ReplayTouch = {
  seq: number;
  time: number;
  type: "file" | "command";
  verb: "read" | "edit" | "run";
  /** The path, or the command line. */
  text: string;
  failed: boolean;
};

export type ReplayTimeline = {
  /** Each event's seq and replay time (ms after the first event), oldest first. */
  steps: { seq: number; time: number }[];
  /** Replay time of the last event. */
  duration: number;
  tools: ReplayMark[];
  /** Each finished turn's `turn_result`: where Continue from here can fork. */
  turnEnds: { seq: number; time: number }[];
  /** What the tool calls touched, in the order the calls started. */
  touches: ReplayTouch[];
};

/// Speeds the replay bar steps through, slowest first.
export const REPLAY_SPEEDS = [0.5, 1, 2, 4, 10, 16] as const;

/// A replay starts at 10×, like a video scrubbed fast (Leo, 2026-11-19: "Scrub a chat's history like a
/// video at 10x, with the files and commands it touched").
export const DEFAULT_REPLAY_SPEED = 10;

type Call = { seq: number; time: number; item: AcpmuxActivity };

export function replayTimeline(events: readonly EventRecord[]): ReplayTimeline {
  const steps: ReplayTimeline["steps"] = [];
  const tools: ReplayMark[] = [];
  const turnEnds: ReplayTimeline["turnEnds"] = [];
  // Each tool call folded as the transcript folds it, and where it started.
  const calls = new Map<string, Call>();
  let time = 0;
  let previous: number | undefined;
  for (const event of [...events].sort((a, b) => a.seq - b.seq)) {
    const at = Number.isFinite(event.at) ? event.at : (previous ?? 0);
    if (previous !== undefined) time += Math.min(Math.max(at - previous, 0), IDLE_GAP_MS);
    previous = at;
    steps.push({ seq: event.seq, time });
    const update = event.dir === "in" && event.msg?.method === "session/update" ? event.msg.params?.update : undefined;
    if (update?.sessionUpdate === "tool_call")
      tools.push({ seq: event.seq, time, label: String(update.title ?? update.kind ?? "") });
    if (
      (update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update") &&
      typeof update.toolCallId === "string"
    ) {
      const call = calls.get(update.toolCallId);
      const item = mergeToolItem(call?.item, update, update.toolCallId, "", at);
      calls.set(update.toolCallId, { seq: call?.seq ?? event.seq, time: call?.time ?? time, item });
    }
    if (event.dir === "mux" && event.kind === "turn_result") turnEnds.push({ seq: event.seq, time });
  }
  return { steps, duration: time, tools, turnEnds, touches: touchesOf([...calls.values()]) };
}

/// The files and commands each call touched: a shell call's command line, a read's or an edit's
/// files (read off each harness's input as the edited-files rows read them, toolPaths.ts). Other
/// calls (search, fetch, think) touch nothing listed.
function touchesOf(calls: Call[]): ReplayTouch[] {
  const touches: ReplayTouch[] = [];
  for (const { seq, time, item } of calls.sort((a, b) => a.seq - b.seq)) {
    const tool = item.tool;
    if (!tool) continue;
    const failed = tool.status === "failed";
    const command = tool.command?.trim();
    if (command) touches.push({ seq, time, type: "command", verb: "run", text: command, failed });
    else if (tool.kind === "read" || tool.kind === "edit" || tool.kind === "delete" || tool.kind === "move") {
      const verb = tool.kind === "read" ? "read" : "edit";
      for (const path of editedPaths(tool)) touches.push({ seq, time, type: "file", verb, text: path, failed });
    }
  }
  return touches;
}

/** How many of `touches` started at or before event `throughSeq`. */
export function touchesThrough(touches: readonly ReplayTouch[], throughSeq: number): number {
  let low = 0;
  let high = touches.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (touches[middle]!.seq <= throughSeq) low = middle + 1;
    else high = middle;
  }
  return low;
}

export type TouchedFile = { path: string; edited: boolean; last: ReplayTouch };

/** The files in `touches`, each once, in first-touch order: edited once a call edited it. */
export function touchedFiles(touches: readonly ReplayTouch[]): TouchedFile[] {
  const files = new Map<string, TouchedFile>();
  for (const touch of touches) {
    if (touch.type !== "file") continue;
    const edited = touch.verb === "edit" && !touch.failed;
    const file = files.get(touch.text);
    if (file) {
      file.edited ||= edited;
      file.last = touch;
    } else files.set(touch.text, { path: touch.text, edited, last: touch });
  }
  return [...files.values()];
}

/** A path as the list shows it: from the chat's folder when it is inside it. */
export function shownPath(path: string, cwd?: string): string {
  const folder = cwd?.replace(/\/+$/, "");
  return folder && path.startsWith(`${folder}/`) ? path.slice(folder.length + 1) : path;
}

/** The last event at or before replay time `time`, which the transcript shows through (0: none). */
export function seqAt(timeline: ReplayTimeline, time: number): number {
  const { steps } = timeline;
  let low = 0;
  let high = steps.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (steps[middle]!.time <= time) low = middle + 1;
    else high = middle;
  }
  return low === 0 ? 0 : steps[low - 1]!.seq;
}

/** `m:ss` for the replay clock. */
export function clockLabel(ms: number): string {
  const seconds = Math.floor(Math.max(ms, 0) / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/// Within this much after a tool call's start, previous goes to the call before it (a media
/// player's previous track).
const RESTART_WINDOW_MS = 750;

/** The tool call to jump to from replay time `time`: the next one, or the previous one. */
export function toolMark(
  timeline: ReplayTimeline,
  time: number,
  direction: "next" | "previous",
): ReplayMark | undefined {
  if (direction === "next") return timeline.tools.find((mark) => mark.time > time);
  let previous: ReplayMark | undefined;
  for (const mark of timeline.tools) if (mark.time < time - RESTART_WINDOW_MS) previous = mark;
  return previous;
}

/** The last turn finished by replay time `time`, which Continue from here forks through. */
export function continueSeq(timeline: ReplayTimeline, time: number): number | undefined {
  // A binary search: playback asks every frame, and a long chat has thousands of turns.
  const { turnEnds } = timeline;
  let low = 0;
  let high = turnEnds.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (turnEnds[middle]!.time <= time) low = middle + 1;
    else high = middle;
  }
  return low === 0 ? undefined : turnEnds[low - 1]!.seq;
}
