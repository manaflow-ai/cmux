// The flicker detector's batches reach the app on both hosts (flickerLog.ts). On the shared page host
// it started nowhere, so Leo's NIGHTLY ring file (2026-11-11, "the tool calls coming in are still
// kinda sluggish") held 369 lines and no page event: no `frames`, no `long-frame`.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  FlickerLog,
  FRAME_WATCH_KEY,
  frameWatchFlag,
  pageHostFlickerSend,
  resetFlickerLogForTests,
  setFrameWatch,
  startFlickerLog,
  type FlickerEvent,
} from "./flickerLog";
import { resetPageHostClientForTests } from "./pageHost";

const scope = globalThis as Record<string, unknown>;
const previousWebkit = scope.webkit;

function page(): Window {
  return new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true })
    .window as unknown as Window;
}

function event(win: Window, name: string): Event {
  return new (win as Window & typeof globalThis).Event(name);
}

/// Ends the page's flush window at once, as leaving the page does.
function leave(win: Window): void {
  win.dispatchEvent(event(win, "pagehide"));
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  resetFlickerLogForTests();
  resetPageHostClientForTests();
  if (previousWebkit === undefined) delete scope.webkit;
  else scope.webkit = previousWebkit;
});

test("on the shared page host each batch is the cmux.agent.diag.flicker op", async () => {
  const calls: { t: string; op?: string; params?: { events: FlickerEvent[] } }[] = [];
  scope.webkit = {
    messageHandlers: {
      cmuxPage: {
        async postMessage(message: { t: string; id: number; op?: string; params?: { events: FlickerEvent[] } }) {
          calls.push(message);
          return { t: "ok", id: message.id, value: null };
        },
      },
    },
  };
  const win = page();
  startFlickerLog(win, pageHostFlickerSend());
  leave(win);
  await settle();
  const sent = calls.filter((call) => call.t === "call");
  expect(sent.map((call) => call.op)).toEqual(["cmux.agent.diag.flicker"]);
  expect(sent[0]!.params!.events.map((event) => event.kind)).toEqual(["page-load"]);
  expect(typeof sent[0]!.params!.events[0]!.at).toBe("number");
});

test("a host that refuses or throws costs the page nothing", async () => {
  scope.webkit = {
    messageHandlers: {
      cmuxPage: {
        async postMessage(message: { id: number }) {
          return { t: "err", id: message.id, code: "cmux.protocol.unknown_op", message: "no such op" };
        },
      },
    },
  };
  const refused = page();
  startFlickerLog(refused, pageHostFlickerSend());
  expect(() => leave(refused)).not.toThrow();
  await settle();

  resetFlickerLogForTests();
  const throwing = page();
  startFlickerLog(throwing, () => {
    throw new Error("gone");
  });
  expect(() => leave(throwing)).not.toThrow();
});

test("the old host's WebKit handler still takes them, and the gallery's stand-in gets none", async () => {
  const posted: { method: string }[] = [];
  const old = page();
  (old as unknown as { webkit: unknown }).webkit = {
    messageHandlers: { agentSession: { postMessage: async (body: { method: string }) => posted.push(body) } },
  };
  startFlickerLog(old);
  leave(old);
  expect(posted.map((body) => body.method)).toEqual(["diag.flicker"]);

  resetFlickerLogForTests();
  const gallery = page();
  (gallery as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: { standIn: true, postMessage: async (body: { method: string }) => posted.push(body) },
    },
  };
  startFlickerLog(gallery);
  leave(gallery);
  expect(posted).toHaveLength(1);
});

test("events wait for their batch: nothing goes out before the second ends or the page leaves", async () => {
  const batches: FlickerEvent[][] = [];
  const win = page();
  startFlickerLog(win, (events) => batches.push(events));
  win.document.dispatchEvent(event(win, "visibilitychange"));
  expect(batches).toHaveLength(0);
  leave(win);
  expect(batches.map((batch) => batch.map((sent) => sent.kind))).toEqual([["page-load", "visibility"]]);
});

test("a record at rest arms no timer: each recording task's records go out as one batch at its end", async () => {
  const batches: string[][] = [];
  let now = 10_000;
  const log = new FlickerLog(
    (events) => batches.push(events.map((sent) => sent.kind)),
    () => now,
  );
  // A chat switch's records, in one task: one batch after it.
  log.transcriptMounted();
  log.record("transcript-replace");
  expect(batches).toHaveLength(0);
  await settle();
  expect(batches).toEqual([["transcript-mount", "transcript-replace"]]);
  // A record 300 ms later (the switch's long frame, reaching the observer late) goes out at the end of its own
  // task too: before, it armed a timer for the rest of the second, which woke the chat at rest.
  now += 300;
  log.record("frames");
  log.record("long-frame");
  await settle();
  expect(batches.at(-1)).toEqual(["frames", "long-frame"]);
  expect(batches).toHaveLength(2);
});

/// A page that counts the display frames asked of it. Hidden, so the first-load watch (firstLoadWatch.ts,
/// bounded by the load) asks for none and every frame counted is the frame watch's (it asks for frames
/// hidden or not, and times only visible ones).
function countingPage(): { win: Window; frames: () => number; watching: () => number } {
  const win = page();
  Object.defineProperty(win.document, "visibilityState", { value: "hidden", configurable: true });
  let frames = 0;
  win.requestAnimationFrame = () => {
    frames += 1;
    return frames;
  };
  // The frame watch's observers that are connected: the only ones that take text changes and no attributes.
  const connected = new Set<MutationObserver>();
  const Base = (win as Window & typeof globalThis).MutationObserver;
  (win as Window & typeof globalThis).MutationObserver = class extends Base {
    override observe(target: Node, options?: MutationObserverInit): void {
      if (options?.characterData && !options.attributes) connected.add(this);
      super.observe(target, options);
    }
    override disconnect(): void {
      connected.delete(this);
      super.disconnect();
    }
  };
  return { win, frames: () => frames, watching: () => connected.size };
}

function mutate(win: Window): void {
  win.document.body.append(win.document.createElement("span"));
}

test("CMUX-672: a DOM change asks for no frame unless the frame watch's debug flag is on", async () => {
  const { win, frames, watching } = countingPage();
  try {
    startFlickerLog(win, () => undefined);
    mutate(win);
    await settle();
    // Before, every change on every page armed a second of frames (the shared renderer at 96 to 157% CPU).
    expect(frames()).toBe(0);
    expect(watching()).toBe(0);

    setFrameWatch(true, win);
    expect(win.localStorage.getItem(FRAME_WATCH_KEY)).toBe("on");
    expect(watching()).toBe(1);
    mutate(win);
    await settle();
    expect(frames()).toBeGreaterThan(0);

    // Off again: the observer is disconnected (stop condition), and turning it on twice made only one.
    setFrameWatch(true, win);
    expect(watching()).toBe(1);
    setFrameWatch(false, win);
    expect(watching()).toBe(0);
    expect(frameWatchFlag(win)).toBe(false);
  } finally {
    win.localStorage.removeItem(FRAME_WATCH_KEY);
  }
});

test("the frame watch follows the flag set in another page, and a page loaded with it on watches", async () => {
  const first = countingPage();
  const later = countingPage();
  try {
    startFlickerLog(first.win, () => undefined);
    // Another page of the origin turned it on: this page hears the storage event.
    first.win.localStorage.setItem(FRAME_WATCH_KEY, "on");
    first.win.dispatchEvent(
      new (first.win as Window & typeof globalThis).StorageEvent("storage", { key: FRAME_WATCH_KEY }),
    );
    expect(first.watching()).toBe(1);
    mutate(first.win);
    await settle();
    expect(first.frames()).toBeGreaterThan(0);
    // And off the same way.
    first.win.localStorage.removeItem(FRAME_WATCH_KEY);
    first.win.dispatchEvent(
      new (first.win as Window & typeof globalThis).StorageEvent("storage", { key: FRAME_WATCH_KEY }),
    );
    expect(first.watching()).toBe(0);
    resetFlickerLogForTests();

    later.win.localStorage.setItem(FRAME_WATCH_KEY, "on");
    startFlickerLog(later.win, () => undefined);
    expect(later.watching()).toBe(1);
    mutate(later.win);
    await settle();
    expect(later.frames()).toBeGreaterThan(0);
  } finally {
    first.win.localStorage.removeItem(FRAME_WATCH_KEY);
    later.win.localStorage.removeItem(FRAME_WATCH_KEY);
  }
});
