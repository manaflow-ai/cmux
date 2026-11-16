import { MockAcpmuxSocket } from "./mock";

// Benchmark-only traffic, through the mock daemon and the real reducer. No frame observer,
// scrolling or layout reads: those would add measurement work to the key's critical path.
export type TypingLoadOptions = {
  stop?: boolean;
  chunks_per_second?: number;
  tool_lines_per_second?: number;
  seconds?: number;
};
let active:
  | {
      stopped: boolean;
      done: Promise<unknown>;
      receipt: {
        running: boolean;
        started_epoch_ms: number;
        finished_epoch_ms: number | null;
        deltas: number;
        toolLines: number;
        elapsedMs: number;
        maxGapMs: number;
        error?: string;
      };
    }
  | undefined;

export async function typingLoad(
  session: string | undefined,
  options: TypingLoadOptions = {},
): Promise<Record<string, unknown>> {
  if (options.stop) {
    if (!active) return { error: "no typing load" };
    active.stopped = true;
    await active.done;
    return { ...active.receipt };
  }
  // With no rate, read the receipt without starting or resetting the generator.
  if (options.chunks_per_second === undefined) return active ? { ...active.receipt } : { error: "no typing load" };
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
    receipt: {
      running: true,
      started_epoch_ms: performance.timeOrigin + performance.now(),
      finished_epoch_ms: null as number | null,
      deltas: 0,
      toolLines: 0,
      elapsedMs: 0,
      maxGapMs: 0,
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
      toolLinesPerSecond: lines,
      stopped: () => state.stopped,
      progress: (counts) => Object.assign(state.receipt, counts),
    })
    .catch((error: unknown) => {
      state.receipt.error = String(error);
    })
    .finally(() => {
      state.receipt.running = false;
      state.receipt.finished_epoch_ms = performance.timeOrigin + performance.now();
    });
  return { ...state.receipt };
}
