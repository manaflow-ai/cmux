import { expect, test } from "bun:test";
import {
  authoritativeScrollIntent,
  createScrollPacer,
  type ScrollFrame,
} from "../src/agent-session/acpmux/scrollPacer";

test("stale queued latest state cannot retake a parked reader", () => {
  expect(
    authoritativeScrollIntent({
      top: 240,
      scrollHeight: 2_000,
      clientHeight: 700,
      following: false,
      jumping: false,
      deadband: 4,
    }),
  ).toBe(false);
  expect(
    authoritativeScrollIntent({
      top: 1_296,
      scrollHeight: 2_000,
      clientHeight: 700,
      following: true,
      jumping: false,
      deadband: 4,
    }),
  ).toBe(true);
  expect(
    authoritativeScrollIntent({
      top: 240,
      scrollHeight: 2_000,
      clientHeight: 700,
      following: false,
      jumping: true,
      deadband: 4,
    }),
  ).toBe(true);
});

test("scroll updates commit once per frame and keep the latest offset", () => {
  const callbacks = new Map<number, FrameRequestCallback>();
  let nextHandle = 0;
  const committed: ScrollFrame[] = [];
  const pacer = createScrollPacer(
    (frame) => committed.push(frame),
    (callback) => {
      const handle = ++nextHandle;
      callbacks.set(handle, callback);
      return handle;
    },
    (handle) => callbacks.delete(handle),
  );

  pacer.enqueue({ top: 40, atLatest: false });
  pacer.enqueue({ top: 80, atLatest: true });
  expect(committed).toEqual([]);
  expect(callbacks).toHaveLength(1);
  const run = (handle: number, time: number) => {
    const callback = callbacks.get(handle);
    callbacks.delete(handle);
    callback?.(time);
  };
  run(1, 0);
  expect(committed).toEqual([{ top: 80, atLatest: true }]);

  pacer.enqueue({ top: 120, atLatest: false });
  pacer.cancel();
  run(2, 16);
  expect(committed).toEqual([{ top: 80, atLatest: true }]);
  expect(callbacks).toHaveLength(0);
});
