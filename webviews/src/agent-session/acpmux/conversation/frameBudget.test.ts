// The chat goes to its minimal motion when its frames miss their budget, and back once they hold it,
// with hysteresis (Leo, 2026-11-09: "at really high loads if it knows it can't performantly perform
// the animation... it just goes into minimal ish mode?").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createFrameBudget, FrameBudgetState, HEALTHY_FOR, IDLE_FRAMES, minimalMotion } from "./frameBudget";
import { motionMode } from "../../../ui/motion/motionMode";

const FRAME = 1000 / 60;

test("healthy frames never go minimal", () => {
  const state = new FrameBudgetState();
  for (let at = 0; at < 3000; at += FRAME) state.frame(FRAME, at);
  expect(state.minimal).toBe(false);
});

test("a second of dropped frames goes minimal, and only HEALTHY_FOR of healthy frames comes back", () => {
  const state = new FrameBudgetState();
  let now = 0;
  // 50 ms frames: each misses about 17 ms past two frames; seven of them cross the bound.
  for (let index = 0; index < 8; index += 1) state.frame(50, (now += 50));
  expect(state.minimal).toBe(true);
  // A short healthy stretch is not enough.
  for (let elapsed = 0; elapsed < HEALTHY_FOR / 2; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(true);
  // One more janky frame starts the healthy count over.
  state.frame(60, (now += 60));
  for (let elapsed = 0; elapsed < HEALTHY_FOR - 100; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(true);
  for (let elapsed = 0; elapsed < 200; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(false);
});

test("load the chat keeps meeting goes minimal; one long task or a page back from hidden does not", () => {
  const state = new FrameBudgetState();
  expect(state.frame(30_000, 30_000)).toBe(false);
  expect(state.minimal).toBe(false);
  // One burst (a long chat's first draw): its long task and the frame it held, then frames in budget.
  state.busy(200, 30_100);
  state.frame(250, 30_100);
  for (let at = 30_100; at < 31_000; at += FRAME) state.frame(FRAME, at);
  expect(state.minimal).toBe(false);
  // A long task every 500 ms (the bench's synthetic load): the misses spread over the window.
  state.busy(70, 32_000);
  expect(state.minimal).toBe(false);
  state.busy(70, 32_500);
  expect(state.minimal).toBe(true);
});

test("the page's mark: the gate moves nothing, the loop stops when idle, and dispose takes it away", () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=chat></div></body></html>", { pretendToBeVisual: true });
  const doc = dom.window.document;
  const queue: ((time: number) => void)[] = [];
  let now = 0;
  const budget = createFrameBudget(doc, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
  });
  const run = (gap: number) => {
    now += gap;
    const next = queue.splice(0);
    for (const callback of next) callback(now);
    return next.length;
  };
  budget.poke();
  for (let index = 0; index < 10; index += 1) run(60);
  expect(budget.minimal).toBe(true);
  expect(doc.documentElement.getAttribute("data-chat-motion")).toBe("minimal");
  expect(minimalMotion(doc.getElementById("chat"))).toBe(true);
  expect(motionMode(doc)).toBe("none");
  // Healthy again: the mark goes, and with no poke the loop stops.
  let frames = 0;
  while (run(FRAME) > 0 && frames < 2000) frames += 1;
  expect(budget.minimal).toBe(false);
  expect(doc.documentElement.hasAttribute("data-chat-motion")).toBe(false);
  expect(frames).toBeLessThan(2000);
  expect(queue.length).toBe(0);
  // Idle: a poke reads IDLE_FRAMES frames and stops.
  budget.poke();
  let idle = 0;
  while (run(FRAME) > 0) idle += 1;
  expect(idle).toBe(IDLE_FRAMES);
  budget.dispose();
  expect(doc.documentElement.hasAttribute("data-chat-motion")).toBe(false);
});
