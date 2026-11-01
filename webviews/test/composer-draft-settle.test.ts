// An update's relaunch is a quit: the host asks every chat page `pane.wakeState` (within a second)
// before the process ends. The page waits there for the typed draft to reach acpmux, so the last
// keystroke is never a write still on its way when the app goes.
import { afterEach, beforeEach, expect, test } from "bun:test";
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
const writeLimits = { ...draftWriteLimits };

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

beforeEach(async () => {
  // The queue is module-wide: drafts another test file typed with no writer installed are still
  // queued. acpmux takes them at once here, so each test starts from an empty queue.
  scope.window = { cmuxAcpmuxActions: { "chat.writeDraft": async () => undefined } };
  await settlePendingDraftWrites();
});

afterEach(async () => {
  // Answer every write a test left waiting, so no later test inherits a drain or a web-swap hold.
  for (let round = 0; round < 20; round += 1) {
    currentWriter?.release();
    await tick();
  }
  await settlePendingDraftWrites();
  Object.assign(draftWriteLimits, writeLimits);
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

// A page with nothing else on it: only the composer's draft hold can answer.
const emptyPage = { activeElement: null, defaultView: null, querySelector: () => null, querySelectorAll: () => [] };
const composerHold = () => webSwapHold(emptyPage as unknown as Document);

test("a draft write that never answers fails after its timeout, and the web-swap hold ends once it lands", async () => {
  draftWriteLimits.timeoutMs = 20;
  const writer = installWriter();
  writePersistedDraft("timeout-a", "stuck");
  // Without the timeout this drain, and with it the web-update hold, would never end.
  await settlePendingDraftWrites();
  expect(hasPendingDraftWrite("timeout-a")).toBe(true);
  expect(composerHold()).toBe("composer.draft-unsaved");
  writer.release(); // it lands after all: its queued retry goes, it would only land over a later edit
  await tick();
  expect(hasPendingDraftWrite("timeout-a")).toBe(false);
  expect(composerHold()).toBeNull();
  expect(writer.landed.map((write) => write.text)).toEqual(["stuck"]);
});

/** A writer whose writes land only when `land(i)` is called, in any order. */
function orderedWriter(): { landed: string[]; land: (index: number) => void } {
  const landed: string[] = [];
  const writes: (() => void)[] = [];
  scope.window = {
    cmuxAcpmuxActions: {
      "chat.writeDraft": (params: Record<string, unknown>) =>
        new Promise<void>((resolve) => {
          writes.push(() => {
            landed.push(String(params.text));
            resolve();
          });
        }),
    },
  };
  return { landed, land: (index) => writes[index]?.() };
}

test("nothing newer goes on the connection while a timed-out write may still land", async () => {
  draftWriteLimits.timeoutMs = 20;
  const writer = orderedWriter();
  writePersistedDraft("late-a", "old");
  await settlePendingDraftWrites(); // "old" times out, still on its way
  writePersistedDraft("late-a", ""); // the person cleared the prompt
  await settlePendingDraftWrites();
  expect(writer.landed).toEqual([]); // the clear waits, so "old" cannot land over it
  expect(composerHold()).toBe("composer.draft-unsaved");
  writer.land(0); // "old" lands late
  await tick();
  const settled = settlePendingDraftWrites();
  writer.land(1); // then the clear, last
  await settled;
  expect(writer.landed).toEqual(["old", ""]);
  expect(hasPendingDraftWrite("late-a")).toBe(false);
  expect(composerHold()).toBeNull();
});

test("a write that never answers holds a web swap only for a while, and a refusal lets the queue go on", async () => {
  draftWriteLimits.timeoutMs = 20;
  const landed: string[] = [];
  let refuse: (() => void) | undefined;
  let calls = 0;
  scope.window = {
    cmuxAcpmuxActions: {
      "chat.writeDraft": (params: Record<string, unknown>) =>
        calls++ === 0
          ? new Promise<void>((_, reject) => (refuse = () => reject(new Error("gone"))))
          : Promise.resolve().then(() => void landed.push(String(params.text))),
    },
  };
  writePersistedDraft("hung-a", "one");
  await settlePendingDraftWrites(); // never answers: times out
  writePersistedDraft("hung-a", "two");
  await settlePendingDraftWrites();
  expect(composerHold()).toBe("composer.draft-unsaved");
  draftWriteLimits.lateHoldMs = 0; // past the late-write hold: a web update may reload the page
  expect(composerHold()).toBeNull();
  refuse?.(); // "one" never landed: the queue goes on
  await tick();
  await settlePendingDraftWrites();
  expect(landed).toEqual(["two"]);
  expect(hasPendingDraftWrite("hung-a")).toBe(false);
});

test("a new connection does not wait for the old connection's unanswered write", async () => {
  draftWriteLimits.timeoutMs = 20;
  const first = installWriter();
  writePersistedDraft("late-b", "old");
  await settlePendingDraftWrites(); // times out on the first connection
  const writer = installWriter(); // a reconnect installs new actions
  const settled = settlePendingDraftWrites();
  await tick();
  writer.release();
  await settled;
  expect(writer.landed.map((write) => write.text)).toEqual(["old"]);
  expect(hasPendingDraftWrite("late-b")).toBe(false);
  first.release(); // the old request ends; it no longer holds anything
  await tick();
  expect(composerHold()).toBeNull();
});

test("a saved draft stays the quit's comparison until its composer leaves the chat", async () => {
  const writer = installWriter();
  writePersistedDraft("saved-a", "one");
  writer.release();
  await settlePendingDraftWrites();
  // A quit must not write it again: another pane may have changed the draft since.
  expect(lastQueuedDraftText("saved-a")).toBe("one");
  forgetQueuedDraft("saved-a");
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
