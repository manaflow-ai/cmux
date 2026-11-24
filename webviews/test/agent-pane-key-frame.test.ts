// A keystroke paints before the stream's next draw (Leo, 2026-11-17: "why should typing... wait on
// rendering???"). The transcript's frame scheduler (`nextFrame`) ran the stream's draw in the first
// frame after a key, and the letter painted only after it: key to frame p50 1.6 ms idle against
// 12.9 ms while a reply streamed (bench/composer-typing.bench.ts, 1,500 rows). The first frame after
// a key now draws none of the stream; the draw takes the next frame. Once per key, every draw asked
// for in that frame alike, and never the 50 ms fallback, which stays the bound.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let frames = new Map<number, (time: number) => void>();
let frameIds = 0;
let frameTime = 1000;

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.requestAnimationFrame = (run: (time: number) => void) => {
    frameIds += 1;
    frames.set(frameIds, run);
    return frameIds;
  };
  scope.cancelAnimationFrame = (id: number) => frames.delete(id);
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => "visible" });
});

afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

beforeEach(() => {
  frames = new Map();
});

const { nextFrame } = await import("../src/agent-session/acpmux/direct");

/// One display frame: every callback asked for before it, with the frame's time.
function drawFrame(): void {
  frameTime += 16.7;
  const due = [...frames.values()];
  frames = new Map();
  for (const run of due) run(frameTime);
}

function key(): void {
  dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "a" }));
}

test("with no key, the stream draws in the next frame", () => {
  let drawn = 0;
  nextFrame(() => (drawn += 1));
  drawFrame();
  expect(drawn).toBe(1);
});

test("the first frame after a key draws none of the stream; the next draws it", () => {
  let drawn = 0;
  nextFrame(() => (drawn += 1));
  key();
  drawFrame();
  expect(drawn).toBe(0);
  drawFrame();
  expect(drawn).toBe(1);
});

test("every draw asked for in the key's frame waits, not only the first", () => {
  const drawn: string[] = [];
  nextFrame(() => drawn.push("this chat"));
  nextFrame(() => drawn.push("another chat"));
  key();
  drawFrame();
  expect(drawn).toEqual([]);
  drawFrame();
  expect(drawn).toEqual(["this chat", "another chat"]);
});

test("one key defers the stream once: a draw asked for after it is not deferred again", () => {
  let drawn = 0;
  nextFrame(() => (drawn += 1));
  key();
  drawFrame();
  drawFrame();
  expect(drawn).toBe(1);
  nextFrame(() => (drawn += 1));
  drawFrame();
  expect(drawn).toBe(2);
});

test("the 50 ms fallback draws even right after a key", async () => {
  // No display frame comes (an occluded window): the fallback timer draws.
  let drawn = 0;
  nextFrame(() => (drawn += 1));
  await new Promise((resolve) => setTimeout(resolve, 40));
  key();
  await new Promise((resolve) => setTimeout(resolve, 30));
  expect(drawn).toBe(1);
});
