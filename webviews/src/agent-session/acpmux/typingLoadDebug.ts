import { MockAcpmuxSocket } from "./mock";

// Benchmark-only traffic, through the mock daemon and the real reducer. No frame observer,
// scrolling or layout reads: those would add measurement work to the key's critical path.
export type TypingLoadOptions = {
  stop?: boolean;
  /// Start the measurement window now: `windowMaxGapMs` and `windowMaxScheduleOffsetMs` cover only
  /// the chunks sent after it. The run's own maxima (`maxGapMs`, `maxScheduleOffsetMs`) stay as they are.
  mark?: boolean;
  chunks_per_second?: number;
  tool_lines_per_second?: number;
  seconds?: number;
};
let active:
  | {
      stopped: boolean;
      done: Promise<unknown>;
      /// When the window opened (`mark`); a gap or lateness that began before it counts from here.
      markAtMs: number;
      receipt: {
        running: boolean;
        started_epoch_ms: number;
        finished_epoch_ms: number | null;
        deltas: number;
        toolLines: number;
        elapsedMs: number;
        maxGapMs: number;
        maxScheduleOffsetMs: number;
        windowMaxGapMs: number;
        windowMaxScheduleOffsetMs: number;
        /// Where the window's longest gap ended, in ms after the mark: when the stream stalled.
        windowMaxGapEndMs: number;
        error?: string;
      };
    }
  | undefined;

function snapshot(receipt: Record<string, unknown>) {
  return { ...receipt, epoch_clock_error_ms: Date.now() - (performance.timeOrigin + performance.now()) };
}

export async function typingLoad(
  session: string | undefined,
  options: TypingLoadOptions = {},
): Promise<Record<string, unknown>> {
  if (options.stop) {
    if (!active) return { error: "no typing load" };
    const current = active;
    current.stopped = true;
    await current.done;
    return snapshot(current.receipt);
  }
  if (options.mark) {
    if (!active) return { error: "no typing load" };
    active.markAtMs = performance.now();
    active.receipt.windowMaxGapMs = 0;
    active.receipt.windowMaxScheduleOffsetMs = 0;
    active.receipt.windowMaxGapEndMs = 0;
    return snapshot(active.receipt);
  }
  // With no rate, read the receipt without starting or resetting the generator.
  if (options.chunks_per_second === undefined) return active ? snapshot(active.receipt) : { error: "no typing load" };
  if (active?.receipt.running) return { error: "typing load already running" };
  const mock = MockAcpmuxSocket.live;
  if (!mock || !session) return { error: "typing load requires a seeded mock session" };
  const rate = options.chunks_per_second;
  const lines = options.tool_lines_per_second ?? 0;
  const seconds = options.seconds ?? 120;
  if (
    ![rate, lines, seconds].every(Number.isFinite) ||
    rate <= 0 ||
    rate > 1000 ||
    lines < 0 ||
    lines > 10000 ||
    seconds <= 0 ||
    seconds > 120
  )
    return { error: "typing load requires rate 1..1000, lines 0..10000, duration (0,120]" };
  const state = {
    stopped: false,
    done: Promise.resolve<unknown>(undefined),
    markAtMs: performance.now(),
    receipt: {
      running: true,
      started_epoch_ms: performance.timeOrigin + performance.now(),
      finished_epoch_ms: null as number | null,
      deltas: 0,
      toolLines: 0,
      elapsedMs: 0,
      maxGapMs: 0,
      maxScheduleOffsetMs: 0,
      windowMaxGapMs: 0,
      windowMaxScheduleOffsetMs: 0,
      windowMaxGapEndMs: 0,
      error: undefined as string | undefined,
    },
  };
  active = state;
  state.done = mock
    .streamLoadTurn(session, {
      seconds,
      chunkChars: 32,
      chunkMs: 1000 / rate,
      toolEvery: 0,
      fixedSchedule: true,
      toolLinesPerSecond: lines,
      stopped: () => state.stopped,
      progress: ({ atMs, previousAtMs, dueAtMs, ...counts }) => {
        Object.assign(state.receipt, counts);
        // Only the part of a gap (or of a chunk's lateness) after the mark is in the window.
        const gap = atMs - Math.max(previousAtMs, state.markAtMs);
        const late = atMs - Math.max(dueAtMs, state.markAtMs);
        if (gap > state.receipt.windowMaxGapMs) {
          state.receipt.windowMaxGapMs = gap;
          state.receipt.windowMaxGapEndMs = atMs - state.markAtMs;
        }
        state.receipt.windowMaxScheduleOffsetMs = Math.max(state.receipt.windowMaxScheduleOffsetMs, late, 0);
      },
    })
    .catch((error: unknown) => {
      state.receipt.error = String(error);
    })
    .finally(() => {
      state.receipt.running = false;
      state.receipt.finished_epoch_ms = performance.timeOrigin + performance.now();
    });
  return snapshot(state.receipt);
}
