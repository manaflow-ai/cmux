// An update's relaunch is a quit: the host asks every chat page `pane.wakeState` (within a second)
// before the process ends. The page waits there for the typed draft to reach acpmux, so the last
// keystroke is never a write still on its way when the app goes.
import { afterEach, expect, test } from "bun:test";
import {
  draftWriteLimits,
  forgetQueuedDraft,
  hasPendingDraftWrite,
  lastQueuedDraftText,
  settleDraftWithin,
  settlePendingDraftWrites,
  writePersistedDraft,
} from "../src/agent-session/acpmux/composerDraft";
import { webSwapHold } from "../src/pages/shared/webSwap";

type Write = { sessionId: string; text: string };
const scope = globalThis as Record<string, unknown>;
const hadWindow = "window" in scope;
const savedWindow = scope.window;
const writeTimeoutMs = draftWriteLimits.timeoutMs;

let currentWriter: { release: () => void } | undefined;

function installWriter(): { landed: Write[]; release: () => void } {
  const landed: Write[] = [];
  let waiting: (() => void)[] = [];
  scope.window = {
    cmuxAcpmuxActions: {
      "chat.writeDraft": (params: Record<string, unknown>) =>
        new Promise<void>((resolve) => {
          waiting.push(() => {
            landed.push(params as Write);
            resolve();
          });
        }),
    },
  };
  const writer = {
    landed,
    release: () => {
      const now = waiting;
      waiting = [];
      for (const run of now) run();
    },
  };
  currentWriter = writer;
  return writer;
}

afterEach(async () => {
  // Answer every write a test left waiting, so no later test inherits a drain or a web-swap hold.
  for (let round = 0; round < 20; round += 1) {
    currentWriter?.release();
    await tick();
  }
  await settlePendingDraftWrites();
  draftWriteLimits.timeoutMs = writeTimeoutMs;
  currentWriter = undefined;
  if (hadWindow) scope.window = savedWindow;
  else delete scope.window;
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a quit waits until acpmux holds the last keystroke, not only the first write", async () => {
  const writer = installWriter();
  writePersistedDraft("settle-a", "hel");
  writePersistedDraft("settle-a", "hello");
  let settled = false;
  const settle = settlePendingDraftWrites().then(() => {
    settled = true;
  });
  await tick();
  expect(settled).toBe(false);
  writer.release(); // "hel" lands; "hello" goes next
  await tick();
  expect(settled).toBe(false);
  writer.release(); // "hello" lands
  await settle;
  expect(writer.landed.map((write) => write.text)).toEqual(["hel", "hello"]);
});

test("nothing queued settles at once", async () => {
  installWriter();
  await settlePendingDraftWrites();
});

test("a write queued as a drain ends starts its own drain and the quit waits for it", async () => {
  const writer = installWriter();
  writePersistedDraft("settle-c", "one");
  const first = settlePendingDraftWrites();
  await tick();
  writer.release(); // "one" lands; the drain ends in the same turn it sees the queue empty
  await first;
  writePersistedDraft("settle-c", "two"); // right after: no drain is left to join
  let settled = false;
  const second = settlePendingDraftWrites().then(() => {
    settled = true;
  });
  await tick();
  expect(settled).toBe(false);
  writer.release();
  await second;
  expect(writer.landed.map((write) => write.text)).toEqual(["one", "two"]);
});

test("the last queued text is what a quit compares the editor's value with", () => {
  installWriter();
  writePersistedDraft("settle-d", "typed");
  expect(lastQueuedDraftText("settle-d")).toBe("typed");
  expect(lastQueuedDraftText("settle-none")).toBeUndefined();
});

test("a draft write that never answers costs the quit at most the cap", async () => {
  installWriter();
  writePersistedDraft("settle-b", "stuck");
  const started = Date.now();
  await settleDraftWithin({ settleDraft: settlePendingDraftWrites }, 30);
  expect(Date.now() - started).toBeLessThan(1000);
});

test("a page without a composer answers at once", async () => {
  await settleDraftWithin(null, 10_000);
});

test("a new chat's settle sends the waiting text and waits for the host's answer", async () => {
  const { createUnsentDraftThrottle } = await import("../src/agent-session/acpmux/unsentDraftThrottle");
  const sent: string[] = [];
  let answer: (() => void) | undefined;
  let clock = 0;
  const throttle = createUnsentDraftThrottle({
    send: (text) => {
      sent.push(text);
      return new Promise<void>((resolve) => (answer = resolve));
    },
    intervalMs: 300,
    now: () => clock,
    setTimer: () => 1,
    clearTimer: () => {},
  });
  throttle.push("h");
  answer?.();
  clock = 10;
  throttle.push("hi"); // inside the interval: waits for the timer
  expect(sent).toEqual(["h"]);
  let settled = false;
  const settle = throttle.settle().then(() => {
    settled = true;
  });
  expect(sent).toEqual(["h", "hi"]);
  await tick();
  expect(settled).toBe(false);
  answer?.();
  await settle;
  throttle.dispose();
});

// The composer's hold is the first one asked, so its reason comes back before the page is read.
const composerHold = () => webSwapHold({} as Document);

test("a draft write that never answers fails after its timeout, and the web-swap ask retries it", async () => {
  draftWriteLimits.timeoutMs = 20;
  const writer = installWriter();
  writePersistedDraft("timeout-a", "stuck");
  // Without the timeout this drain, and with it the web-update hold, would never end.
  await settlePendingDraftWrites();
  expect(hasPendingDraftWrite("timeout-a")).toBe(true);
  expect(composerHold()).toBe("composer.draft-unsaved");
  writer.release(); // acpmux answers again: the hung write and the ask's retry both land
  await settlePendingDraftWrites();
  expect(hasPendingDraftWrite("timeout-a")).toBe(false);
  expect(writer.landed.map((write) => write.text)).toEqual(["stuck", "stuck"]);
});

test("a saved draft leaves the quit's comparison; a newer text stays until it lands too", async () => {
  const writer = installWriter();
  writePersistedDraft("saved-a", "one");
  await tick();
  writePersistedDraft("saved-a", "two");
  writer.release(); // "one" lands while "two" waits
  await tick();
  expect(lastQueuedDraftText("saved-a")).toBe("two");
  writer.release();
  await settlePendingDraftWrites();
  expect(lastQueuedDraftText("saved-a")).toBeUndefined();
});

test("a composer leaving its chat forgets the queued text, and the write still goes", async () => {
  const writer = installWriter();
  writePersistedDraft("closed-a", "typed");
  forgetQueuedDraft("closed-a");
  expect(lastQueuedDraftText("closed-a")).toBeUndefined();
  writer.release();
  await settlePendingDraftWrites();
  expect(writer.landed.map((write) => write.text)).toEqual(["typed"]);
});
