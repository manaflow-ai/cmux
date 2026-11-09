// The page's half of the always-on flicker detector (acpmux/flickerLog.ts; Leo, 2026-11-04: "a
// flicker across nearly the full screen"): events go out in one batch a second with their time, a
// second transcript mount counts as a remount, and a frame over 100 ms while visible is reported
// once, with no frame timed while the page is hidden or after the page stops changing. The frames
// that drew a change are summed up at most once a second (Leo, 2026-11-07: "find, like, where we're
// dropping frames").
import { expect, test } from "bun:test";
import {
  FlickerLog,
  FrameWatch,
  frameStats,
  type FlickerEvent,
  type FrameStats,
} from "../src/agent-session/acpmux/flickerLog";

test("events go out in one batch with their time, and mounts count", () => {
  const sent: FlickerEvent[][] = [];
  let clock = 1_000;
  const timers: (() => void)[] = [];
  const log = new FlickerLog(
    (events) => sent.push(events),
    () => clock,
    (run) => {
      timers.push(run);
      return 0 as unknown as ReturnType<typeof setTimeout>;
    },
  );
  log.record("visibility", { state: "hidden" });
  clock = 1_200;
  log.transcriptMounted();
  log.transcriptMounted();
  expect(timers).toHaveLength(1);
  expect(sent).toHaveLength(0);
  timers[0]!();
  expect(sent).toEqual([
    [
      { kind: "visibility", at: 1_000, state: "hidden" },
      { kind: "transcript-mount", at: 1_200, n: 1 },
      { kind: "transcript-mount", at: 1_200, n: 2 },
    ],
  ]);
  log.flush();
  expect(sent).toHaveLength(1);
});

test("a held burst keeps the newest and counts the dropped", () => {
  const sent: FlickerEvent[][] = [];
  const log = new FlickerLog(
    (events) => sent.push(events),
    () => 0,
    () => 0 as unknown as ReturnType<typeof setTimeout>,
  );
  for (let index = 0; index < 70; index += 1) log.record("long-frame", { ms: index });
  log.flush();
  expect(sent[0]).toHaveLength(64);
  expect(sent[0]![0]).toMatchObject({ ms: 6, dropped: 6 });
  expect(sent[0]!.at(-1)).toMatchObject({ ms: 69 });
});

test("frames are timed only while the page changes, and only while visible", () => {
  const reported: number[] = [];
  let now = 0;
  let visible = true;
  let pending: ((time: number) => void) | undefined;
  const watch = new FrameWatch(
    (ms) => reported.push(ms),
    () => visible,
    (run) => {
      pending = run;
    },
    () => now,
  );
  const frame = (time: number) => {
    now = time;
    const run = pending;
    pending = undefined;
    run?.(time);
  };
  watch.arm();
  frame(16);
  frame(33);
  frame(200); // a 167 ms frame
  frame(216);
  expect(reported).toEqual([167]);
  // Hidden: the gap spans the hidden time, not a frame.
  visible = false;
  frame(900);
  visible = true;
  frame(916);
  expect(reported).toEqual([167]);
  // A second after the last change, the watch stops asking for frames.
  frame(1_001);
  expect(pending).toBeUndefined();
  // A change that itself makes the next frame long is timed from the change.
  now = 5_000;
  watch.arm();
  frame(5_250);
  expect(reported).toEqual([167, 250]);
});

/// A watch on a hand-driven clock: `frame(t)` runs the pending frame at t.
function drivenWatch() {
  const reported: number[] = [];
  const summaries: FrameStats[] = [];
  let now = 0;
  let pending: ((time: number) => void) | undefined;
  const watch = new FrameWatch(
    (ms) => reported.push(ms),
    () => true,
    (run) => {
      pending = run;
    },
    () => now,
    (stats) => summaries.push(stats),
  );
  const frame = (time: number) => {
    now = time;
    const run = pending;
    pending = undefined;
    run?.(time);
  };
  const at = (time: number) => {
    now = time;
  };
  return { watch, frame, at, reported, summaries, pending: () => pending };
}

test("frame stats count the frames a 120 Hz and a 60 Hz display would miss", () => {
  expect(frameStats([], 0)).toBeUndefined();
  expect(frameStats([8.3, 8.4, 8.3, 16.7, 8.3, 30, 60, 8.3, 8.4, 8.3], 1000)).toEqual({
    n: 10,
    p50: 8.4,
    p95: 60,
    max: 60,
    miss120: 3,
    miss60: 2,
    over50: 1,
    ms: 1000,
  });
});

test("a change's frame is counted, frames with no change are not", () => {
  const { watch, frame, at, summaries } = drivenWatch();
  at(0);
  watch.arm();
  frame(5); // draws the change (the time up to it runs from the change: no frame's length)
  frame(13.3); // the interval after the frame that drew it: counted
  frame(21.6); // nothing changed since the frame before last
  frame(30);
  at(32);
  watch.arm(); // a change between frames
  frame(38.3); // draws it: the interval up to this frame came before the change, so it is not counted
  frame(60); // the frame after it 21.7 ms late: a missed 120 Hz frame
  frame(68.3);
  for (let time = 80; time <= 1_100; time += 8.3) frame(time);
  expect(summaries).toEqual([{ n: 2, p50: 21.7, p95: 21.7, max: 21.7, miss120: 1, miss60: 0, over50: 0, ms: 55 }]);
});

test("a streaming page gets one summary a second, and none once it is still", () => {
  const { watch, frame, at, summaries, pending } = drivenWatch();
  at(0);
  watch.arm();
  let time = 0;
  while (time < 2_500) {
    time += 8;
    at(time - 1);
    watch.arm(); // a token lands before every frame
    frame(time);
  }
  // Two whole windows went out while it streamed; the rest goes when the watch stops.
  expect(summaries.map((stats) => stats.n)).toEqual([125, 125]);
  expect(summaries.every((stats) => stats.p50 === 8 && stats.miss120 === 0)).toBe(true);
  while (pending()) frame((time += 8));
  expect(summaries).toHaveLength(3);
  expect(summaries[2]!.miss120).toBe(0);
});

test("a change counts one interval, however many changes one frame draws", () => {
  const { watch, frame, at, summaries } = drivenWatch();
  at(0);
  watch.arm();
  frame(8); // from the change: not a frame
  frame(16); // the interval after the frame that drew the first change
  at(18);
  watch.arm();
  at(20);
  watch.arm(); // two changes before one frame
  frame(24); // the interval before this frame came before them
  frame(40); // this interval follows the frame that drew both: counted once
  frame(48);
  for (let time = 56; time <= 1_100; time += 8) frame(time);
  expect(summaries.map((stats) => stats.n)).toEqual([2]);
  expect(summaries[0]!.max).toBe(16);
});

// Chromium refuses a `setTimeout` called with another receiver ("Illegal invocation"). The log's
// default timer is called as its own method, so it must not be the bare function: in Chromium the
// first record threw, and the transcript's mount record then broke the pane's first draw.
test("the default timer runs with the global receiver, as Chromium requires", () => {
  const real = globalThis.setTimeout;
  const receivers: unknown[] = [];
  const strict = function (this: unknown, run: () => void, ms?: number) {
    receivers.push(this);
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    return real(run, ms);
  };
  globalThis.setTimeout = strict as unknown as typeof setTimeout;
  try {
    const sent: FlickerEvent[][] = [];
    const log = new FlickerLog((events) => sent.push(events));
    expect(() => log.transcriptMounted()).not.toThrow();
    log.flush();
    expect(sent).toHaveLength(1);
    expect(receivers).toHaveLength(1);
  } finally {
    globalThis.setTimeout = real;
  }
});
