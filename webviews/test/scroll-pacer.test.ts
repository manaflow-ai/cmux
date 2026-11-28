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

test("motion commits before paint, replaces a queued frame, and deduplicates its native event", () => {
  const callbacks = new Map<number, FrameRequestCallback>();
  let handle = 0;
  const committed: ScrollFrame[] = [];
  const pacer = createScrollPacer(
    (frame) => committed.push(frame),
    (callback) => {
      callbacks.set(++handle, callback);
      return handle;
    },
    (id) => callbacks.delete(id),
  );
  pacer.enqueue({ top: 80, atLatest: true });
  pacer.flush({ top: 400, atLatest: false });
  expect(committed).toEqual([{ top: 400, atLatest: false }]);
  expect(callbacks).toHaveLength(0);
  pacer.enqueue({ top: 400, atLatest: false });
  pacer.flush({ top: 400, atLatest: false });
  expect(committed).toHaveLength(1);
  expect(callbacks).toHaveLength(0);

  // An intent change at the same offset must survive duplicate suppression.
  pacer.enqueue({ top: 400, atLatest: true });
  expect(callbacks).toHaveLength(1);
  callbacks.get(handle)!(16);
  callbacks.clear();
  expect(committed.at(-1)).toEqual({ top: 400, atLatest: true });
  pacer.flush({ top: 500, atLatest: false });
  expect(committed.at(-1)).toEqual({ top: 500, atLatest: false });
  pacer.cancel();
  pacer.enqueue({ top: 500, atLatest: false });
  expect(callbacks).toHaveLength(1);
});
