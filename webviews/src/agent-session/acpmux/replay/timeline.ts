// Session replay's clock (ReplayScreen.tsx). Playback runs on replay time: the recorded wall clock
// with every quiet gap longer than IDLE_GAP_MS shortened to it, so a chat left open overnight
// still plays through in the time its work took.
import type { EventRecord } from "../direct";

/// The longest pause replay keeps between two recorded events.
export const IDLE_GAP_MS = 2_000;

/** A tool call's start on the timeline: where jump to previous/next tool call lands. */
export type ReplayMark = { seq: number; time: number; label: string };

export type ReplayTimeline = {
  /** Each event's seq and replay time (ms after the first event), oldest first. */
  steps: { seq: number; time: number }[];
  /** Replay time of the last event. */
  duration: number;
  tools: ReplayMark[];
  /** Each finished turn's `turn_result`: where Continue from here can fork. */
  turnEnds: { seq: number; time: number }[];
};

/// Speeds the replay bar steps through, slowest first.
export const REPLAY_SPEEDS = [0.5, 1, 2, 4, 8, 16] as const;

export function replayTimeline(events: readonly EventRecord[]): ReplayTimeline {
  const steps: ReplayTimeline["steps"] = [];
  const tools: ReplayMark[] = [];
  const turnEnds: ReplayTimeline["turnEnds"] = [];
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
    if (event.dir === "mux" && event.kind === "turn_result") turnEnds.push({ seq: event.seq, time });
  }
  return { steps, duration: time, tools, turnEnds };
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
  let seq: number | undefined;
  for (const end of timeline.turnEnds) if (end.time <= time) seq = end.seq;
  return seq;
}
