// A hidden page does no work (Leo, 2026-10-28: "the same goes for EVERYTHING IN THE WEB UI";
// cmuxterm-hq#4878 finding 1). The transcript's frame scheduler (`nextFrame`) fell back to a
// 50 ms timer when no display frame came, so a hidden page drew the shown chat's stream twenty
// times a second that nobody saw. It now waits for the page to show, then draws once.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "requestAnimationFrame"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let visibility: "visible" | "hidden" = "visible";
// Display frames come only when the test draws one; a hidden page gets none.
let frames: (() => void)[] = [];

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.requestAnimationFrame = (run: () => void) => frames.push(run);
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

beforeEach(() => {
  frames = [];
  jest.useFakeTimers();
});

afterEach(() => {
  jest.useRealTimers();
  setVisibility("visible");
});

const { nextFrame } = await import("../src/agent-session/acpmux/direct");

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

function drawFrame(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
}

test("a shown page runs the frame's work once, in its frame", () => {
  let runs = 0;
  nextFrame(() => (runs += 1));
  drawFrame();
  expect(runs).toBe(1);
  jest.advanceTimersByTime(100);
  expect(runs).toBe(1);
});

test("a shown page that draws no frame (an occluded window) still runs it", () => {
  let runs = 0;
  nextFrame(() => (runs += 1));
  jest.advanceTimersByTime(50);
  expect(runs).toBe(1);
});

test("a hidden page runs nothing until it shows, then runs once", () => {
  let runs = 0;
  setVisibility("hidden");
  nextFrame(() => (runs += 1));
  jest.advanceTimersByTime(10_000);
  expect(runs).toBe(0);
  // Another hide changes nothing.
  setVisibility("hidden");
  jest.advanceTimersByTime(1_000);
  expect(runs).toBe(0);
  setVisibility("visible");
  drawFrame();
  expect(runs).toBe(1);
  // The wait's listener went with the show.
  setVisibility("hidden");
  setVisibility("visible");
  drawFrame();
  jest.advanceTimersByTime(100);
  expect(runs).toBe(1);
});

test("a page hidden again before its frame waits for the next show", () => {
  let runs = 0;
  setVisibility("hidden");
  nextFrame(() => (runs += 1));
  setVisibility("visible");
  // Hidden again before the frame came: neither the frame nor the 50 ms fallback runs it.
  setVisibility("hidden");
  drawFrame();
  jest.advanceTimersByTime(1_000);
  expect(runs).toBe(0);
  setVisibility("visible");
  drawFrame();
  expect(runs).toBe(1);
});

test("a cancelled hidden wait runs nothing, and the listener goes with the last wait", () => {
  let runs = 0;
  setVisibility("hidden");
  const added = jest.spyOn(dom.window.document, "addEventListener");
  const removed = jest.spyOn(dom.window.document, "removeEventListener");
  try {
    const cancelFirst = nextFrame(() => (runs += 1));
    const cancelSecond = nextFrame(() => (runs += 10));
    // Every hidden wait shares one listener.
    expect(added.mock.calls.filter(([type]) => type === "visibilitychange").length).toBe(1);
    cancelFirst?.();
    expect(removed.mock.calls.filter(([type]) => type === "visibilitychange").length).toBe(0);
    cancelSecond?.();
    expect(removed.mock.calls.filter(([type]) => type === "visibilitychange").length).toBe(1);
  } finally {
    added.mockRestore();
    removed.mockRestore();
  }
  setVisibility("visible");
  drawFrame();
  jest.advanceTimersByTime(100);
  expect(runs).toBe(0);
});

test("a frame asked for while shown and deferred by a hide still cancels", () => {
  let runs = 0;
  const listening = jest.spyOn(dom.window.document, "addEventListener");
  const stopped = jest.spyOn(dom.window.document, "removeEventListener");
  const count = (spy: typeof listening) => spy.mock.calls.filter(([type]) => type === "visibilitychange").length;
  try {
    // Shown when asked, hidden before its frame: the 50 ms fallback leaves it waiting for the show.
    const cancel = nextFrame(() => (runs += 1));
    setVisibility("hidden");
    jest.advanceTimersByTime(50);
    expect(count(listening)).toBe(1);
    cancel();
    expect(count(stopped)).toBe(1);
    // Cancelled before its fallback fires: nothing starts waiting.
    setVisibility("visible");
    const cancelSoon = nextFrame(() => (runs += 10));
    setVisibility("hidden");
    cancelSoon();
    jest.advanceTimersByTime(50);
    expect(count(listening)).toBe(1);
  } finally {
    listening.mockRestore();
    stopped.mockRestore();
  }
  setVisibility("visible");
  drawFrame();
  jest.advanceTimersByTime(100);
  expect(runs).toBe(0);
});
