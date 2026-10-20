import { afterEach, expect, spyOn, test } from "bun:test";
import { renderWatchdog } from "../src/agent-session/acpmux/conversation/renderWatchdog";

let restore = () => {};
afterEach(() => restore());

function clock() {
  let now = 0,
    next = 100000;
  const tasks = new Map<number, { at: number; run: () => void }>();
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((run: () => void, delay: number) => {
    const id = next++;
    tasks.set(id, { at: now + delay, run });
    return id;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation((id) => {
    tasks.delete(Number(id));
  });
  restore = () => {
    timeout.mockRestore();
    clear.mockRestore();
  };
  return {
    tasks,
    advance(ms: number) {
      const until = now + ms;
      for (;;) {
        const task = [...tasks].sort((a, b) => a[1].at - b[1].at)[0];
        if (!task || task[1].at > until) break;
        tasks.delete(task[0]);
        now = task[1].at;
        task[1].run();
      }
      now = until;
    },
  };
}

test("a frame that never loads expires once after five seconds", () => {
  const time = clock();
  let stops = 0;
  const watch = renderWatchdog(() => stops++);
  time.advance(4999);
  expect(stops).toBe(0);
  time.advance(1);
  expect(stops).toBe(1);
  time.advance(20000);
  expect(stops).toBe(1);
  watch.dispose();
});

test("a responsive frame survives and a later hang expires despite stale or forged replies", () => {
  const time = clock();
  let stops = 0;
  const messages: { type: string; id: string }[] = [];
  const watch = renderWatchdog(() => stops++);
  watch.start({ postMessage: (data: { type: string; id: string }) => messages.push(data) } as unknown as Window);
  const first = messages[0]!.id;
  time.advance(4000);
  watch.pong(first);
  time.advance(2000);
  expect(stops).toBe(0);
  expect(messages.length).toBe(2);
  expect(messages[1]!.id).not.toBe(first);
  time.advance(29999);
  watch.pong(first);
  watch.pong("forged");
  time.advance(1);
  expect(stops).toBe(1);
  watch.pong(messages[1]!.id);
  time.advance(20000);
  expect(messages.length).toBe(2);
  expect(time.tasks.size).toBe(0);
});

test("duplicate replies and ready messages cannot renew a load or response deadline", () => {
  const time = clock();
  let stops = 0;
  let id = "";
  const frame = {
    postMessage: (data: { id: string }) => {
      id = data.id;
    },
  } as unknown as Window;
  const watch = renderWatchdog(() => stops++);
  watch.start(frame);
  const first = id;
  watch.pong(first);
  time.advance(1999);
  watch.pong(first);
  time.advance(1);
  time.advance(29999);
  watch.start(frame);
  watch.pong(first);
  time.advance(1);
  expect(stops).toBe(1);
});

test("unmount cancels both load and heartbeat timers", () => {
  for (const loaded of [false, true]) {
    const time = clock();
    let stops = 0;
    const watch = renderWatchdog(() => stops++);
    if (loaded) watch.start({ postMessage() {} } as unknown as Window);
    watch.dispose();
    time.advance(20000);
    expect(stops).toBe(0);
    expect(time.tasks.size).toBe(0);
    restore();
  }
});

test("a missing heartbeat after document replacement gets a bounded hang grace period", () => {
  const time = clock();
  const reasons: string[] = [];
  let id = "";
  const watch = renderWatchdog((reason) => reasons.push(reason));
  watch.start({
    postMessage: (data: { id: string }) => {
      id = data.id;
    },
  } as unknown as Window);
  watch.pong(id);
  // document.open/document.write can erase the listener after the first successful answer.
  time.advance(2000);
  time.advance(5000);
  expect(reasons).toHaveLength(0);
  time.advance(24999);
  expect(reasons).toHaveLength(0);
  time.advance(1);
  expect(reasons).toEqual(["hang"]);
  time.advance(60000);
  expect(reasons).toEqual(["hang"]);
  expect(time.tasks.size).toBe(0);
});

test("a late matching heartbeat recovers during the post-load grace period", () => {
  const time = clock();
  const reasons: string[] = [];
  let id = "";
  const watch = renderWatchdog((reason) => reasons.push(reason));
  watch.start({
    postMessage: (data: { id: string }) => {
      id = data.id;
    },
  } as unknown as Window);
  watch.pong(id);
  time.advance(12000);
  watch.pong(id);
  expect(reasons).toHaveLength(0);
  time.advance(2000);
  time.advance(29999);
  expect(reasons).toHaveLength(0);
  time.advance(1);
  expect(reasons).toEqual(["hang"]);
});
