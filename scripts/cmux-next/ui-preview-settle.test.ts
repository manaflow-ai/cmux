// ui-preview-settle.mjs: the UI preview shooter shoots the settled frame. Before 2026-11-28 it shot at a fixed 300 ms
// after the frame marked ready, so the chat-motion-pass scene was caught at different points of one entrance fade
// (a false 7.22% diff on every transcript push). These run settle against fake animations in place of a page.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { settle } from "./ui-preview-settle.mjs";

type Fake = {
  playState: string;
  pending: boolean;
  currentTime: number | null;
  effect: { getComputedTiming: () => { endTime: number } };
  finished: Promise<void>;
  finish: () => void;
  pause: () => void;
  end: () => void;
};

let animations: Fake[] = [];
const saved: Record<string, unknown> = {};

function fake(endTime: number): Fake {
  let resolve = () => {};
  const a: Fake = {
    playState: "running",
    pending: false,
    currentTime: 100,
    effect: { getComputedTiming: () => ({ endTime }) },
    finished: new Promise<void>((r) => (resolve = r)),
    finish: () => a.end(),
    pause: () => {
      a.playState = "paused";
    },
    end: () => {
      a.playState = "finished";
      resolve();
    },
  };
  return a;
}

beforeEach(() => {
  animations = [];
  for (const k of ["document", "requestAnimationFrame"]) saved[k] = (globalThis as Record<string, unknown>)[k];
  (globalThis as Record<string, unknown>).document = { getAnimations: () => animations };
  (globalThis as Record<string, unknown>).requestAnimationFrame = (cb: () => void) => setTimeout(cb, 1);
});

afterEach(() => {
  for (const [k, v] of Object.entries(saved)) (globalThis as Record<string, unknown>)[k] = v;
});

test("a page with nothing moving is shot at once", async () => {
  expect(await settle({ bound_ms: 1000 })).toEqual({ passes: 0, waited: 0, finished: 0, paused: 0 });
});

test("an entrance fade is waited on until it ends, then shot", async () => {
  const fade = fake(250);
  animations.push(fade);
  setTimeout(() => fade.end(), 30);
  const started = performance.now();
  const out = await settle({ bound_ms: 2000 });
  expect(fade.playState).toBe("finished");
  expect(out.waited).toBe(1);
  expect(out.finished).toBe(0);
  expect(performance.now() - started).toBeLessThan(1000);
});

test("a fade still running at the bound is finished, so the shot is never mid-motion", async () => {
  const slow = fake(60_000);
  animations.push(slow);
  const out = await settle({ bound_ms: 40 });
  expect(slow.playState).toBe("finished");
  expect(out.finished).toBe(1);
});

test("a spinner is paused at its start and not waited on", async () => {
  const spinner = fake(Infinity);
  animations.push(spinner);
  const out = await settle({ bound_ms: 2000 });
  expect(spinner.playState).toBe("paused");
  expect(spinner.currentTime).toBe(0);
  expect(out).toEqual({ passes: 0, waited: 0, finished: 0, paused: 1 });
});

test("a fade a commit starts after the first one ends is waited on too", async () => {
  const first = fake(100);
  const second = fake(100);
  animations.push(first);
  setTimeout(() => {
    first.end();
    animations.push(second);
    setTimeout(() => second.end(), 20);
  }, 20);
  const out = await settle({ bound_ms: 2000 });
  expect(first.playState).toBe("finished");
  expect(second.playState).toBe("finished");
  expect(out.passes).toBeGreaterThanOrEqual(2);
});
