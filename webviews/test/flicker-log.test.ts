// The page's half of the always-on flicker detector (acpmux/flickerLog.ts; Leo, 2026-11-04: "a
// flicker across nearly the full screen"): events go out in one batch a second with their time, a
// second transcript mount counts as a remount, and a frame over 100 ms while visible is reported
// once, with no frame timed while the page is hidden or after the page stops changing.
import { expect, test } from "bun:test";
import { FlickerLog, FrameWatch, type FlickerEvent } from "../src/agent-session/acpmux/flickerLog";

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
  const log = new FlickerLog((events) => sent.push(events), () => 0, () => 0 as unknown as ReturnType<typeof setTimeout>);
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
