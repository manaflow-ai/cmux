// Session replay's clock (ReplayScreen.tsx). Playback runs on replay time: the recorded wall clock
// with every quiet gap longer than IDLE_GAP_MS shortened to it, so a chat left open overnight
// still plays through in the time its work took.
import type { EventRecord } from "../direct";

/// The longest pause replay keeps between two recorded events.
export const IDLE_GAP_MS = 2_000;

export type ReplayTimeline = {
  /** Each event's seq and replay time (ms after the first event), oldest first. */
  steps: { seq: number; time: number }[];
  /** Replay time of the last event. */
  duration: number;
};

export function replayTimeline(events: readonly EventRecord[]): ReplayTimeline {
  const steps: ReplayTimeline["steps"] = [];
  let time = 0;
  let previous: number | undefined;
  for (const event of [...events].sort((a, b) => a.seq - b.seq)) {
    const at = Number.isFinite(event.at) ? event.at : (previous ?? 0);
    if (previous !== undefined) time += Math.min(Math.max(at - previous, 0), IDLE_GAP_MS);
    previous = at;
    steps.push({ seq: event.seq, time });
  }
  return { steps, duration: time };
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
