// The chat's quiet snapshot write (live.ts watchChatSnapshot) wakes the page once when it has gone quiet, never
// to find it changed and arm again (CMUX-571, idle wakeups: bench/chat-switch.bench.ts idle_wakeups).
import { afterEach, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";
import { noteChatTheme, watchChatSnapshot } from "./live";

let clock = 0;
const now = spyOn(performance, "now").mockImplementation(() => clock);
afterEach(() => now.mockClear());

/// A page whose timers run only when the test says, each counted when it runs.
function page() {
  const win = new JSDOM('<!doctype html><body><div id="root"><p>Reply 1</p></div></body>', {
    url: "http://localhost/",
  }).window as unknown as Window & typeof globalThis;
  const timers = new Map<number, { run: () => void; at: number }>();
  let next = 0;
  let fired = 0;
  win.setTimeout = ((run: () => void, ms = 0) => {
    next += 1;
    timers.set(next, { run, at: clock + ms });
    return next;
  }) as typeof win.setTimeout;
  win.clearTimeout = ((id: number) => void timers.delete(id)) as typeof win.clearTimeout;
  /// Moves the clock to `to`, running each timer due by then, in order.
  const advance = (to: number) => {
    for (;;) {
      const due = [...timers.entries()].filter(([, t]) => t.at <= to).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      clock = due[1].at;
      fired += 1;
      due[1].run();
    }
    clock = to;
  };
  return { win, advance, fired: () => fired, armed: () => timers.size };
}

test("a change while the write waits moves its timer: one wakeup, then the write", async () => {
  noteChatTheme("light");
  clock = 0;
  const { win, advance, fired, armed } = page();
  const writes: Record<string, unknown>[] = [];
  const stop = watchChatSnapshot(
    "chat",
    async (params) => {
      writes.push(params);
      return { kept: true };
    },
    win.document,
  );
  // The chat changes 1 s in (a switch's late rows), before the 1.5 s quiet ran out.
  advance(1000);
  win.document.getElementById("root")!.append(win.document.createElement("p"));
  // The observer's callback runs at the next microtask checkpoint.
  await new Promise<void>((resolve) => queueMicrotask(resolve));
  await new Promise<void>((resolve) => queueMicrotask(resolve));
  advance(10_000);
  expect(writes).toHaveLength(1);
  expect(fired()).toBe(1);
  // At rest after the write: no timer is armed.
  expect(armed()).toBe(0);
  stop();
});
