// The simulated cursor: the hands a person brings to a control, as seeded paths a test replays the
// same way every run. A path is a list of points, each with how many painted frames pass before the
// next one (0: the next move lands in the same frame, a burst of input). Driving goes through
// Playwright's real mouse, so the page gets trusted pointer events, hit testing, capture and :hover.
import type { Page } from "playwright";
import { frames } from "./probe";

export type Point = { x: number; y: number };
export type Step = Point & { wait: number };

/** A tiny seeded PRNG (mulberry32): the same jitter every run. */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export type DragStyle =
  /** A careful hand: 1-2 px a frame. */
  | "slow"
  /** A flick: the whole way in four frames. */
  | "fast"
  /** A shaky hand: the path with ±`amp` px noise on both axes, one point a frame. */
  | "jitter"
  /** Several moves inside one frame (a high-rate mouse, a busy main thread). */
  | "burst"
  /** Past the target by a third of the way, then back. */
  | "overshoot";

/** The points of a drag from `from` to `to` (both included), in `style`. */
export function dragPath(from: Point, to: Point, style: DragStyle, seed = 1, amp = 3): Step[] {
  const dist = Math.hypot(to.x - from.x, to.y - from.y);
  const lerp = (k: number): Point => ({ x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k });
  const line = (n: number, wait: number): Step[] =>
    Array.from({ length: n }, (_, i) => ({ ...lerp((i + 1) / n), wait }));
  switch (style) {
    case "slow":
      return line(Math.max(8, Math.ceil(dist / 1.5)), 1);
    case "fast":
      return line(4, 1);
    case "burst": {
      // Four moves a frame: only every fourth is followed by a frame.
      const n = Math.max(8, Math.ceil(dist / 2));
      return line(n, 0).map((step, i) => ({ ...step, wait: i % 4 === 3 || i === n - 1 ? 1 : 0 }));
    }
    case "jitter": {
      const random = rng(seed);
      const n = Math.max(12, Math.ceil(dist / 3));
      return line(n, 1).map((step, i) =>
        i === n - 1 ? step : { ...step, x: step.x + (random() * 2 - 1) * amp, y: step.y + (random() * 2 - 1) * amp },
      );
    }
    case "overshoot": {
      const past = { x: to.x + (to.x - from.x) / 3, y: to.y + (to.y - from.y) / 3 };
      const n = Math.max(8, Math.ceil(dist / 4));
      const out = Array.from({ length: n }, (_, i) => {
        const k = (i + 1) / n;
        return { x: from.x + (past.x - from.x) * k, y: from.y + (past.y - from.y) * k, wait: 1 };
      });
      const back = Array.from({ length: Math.ceil(n / 2) }, (_, i) => {
        const k = (i + 1) / Math.ceil(n / 2);
        return { x: past.x + (to.x - past.x) * k, y: past.y + (to.y - past.y) * k, wait: 1 };
      });
      return [...out, ...back];
    }
  }
}

/** A press that wobbles `wobble` px around `at` and lets go: what a click is to a real hand. */
export function wobblePath(at: Point, wobble: number, seed = 7): Step[] {
  const random = rng(seed);
  return Array.from({ length: 4 }, () => ({
    x: at.x + (random() * 2 - 1) * wobble,
    y: at.y + (random() * 2 - 1) * wobble,
    wait: 1,
  }));
}

/** Plays `steps` with the button held from the first point (moved to first, button down there). */
export async function drag(page: Page, from: Point, steps: Step[], { release = true } = {}): Promise<void> {
  await page.mouse.move(from.x, from.y);
  await frames(page, 1);
  await page.mouse.down();
  await frames(page, 1);
  await play(page, steps);
  if (release) {
    await page.mouse.up();
    await frames(page, 1);
  }
}

/** Moves along `steps` (no buttons change). */
export async function play(page: Page, steps: Step[]): Promise<void> {
  for (const step of steps) {
    await page.mouse.move(step.x, step.y);
    if (step.wait > 0) await frames(page, step.wait);
  }
}

/** A click at `at`, with `wobble` px of hand shake between press and release. */
export async function click(page: Page, at: Point, { wobble = 0, seed = 7 } = {}): Promise<void> {
  await drag(page, at, wobble > 0 ? wobblePath(at, wobble, seed) : []);
}

/** A double click at `at` (two presses inside the double-click time, as the OS reports them). */
export async function doubleClick(page: Page, at: Point): Promise<void> {
  await page.mouse.move(at.x, at.y);
  await frames(page, 1);
  await page.mouse.dblclick(at.x, at.y);
  await frames(page, 1);
}

/** Points just around a handle's box: the misses a hand makes aiming at it (`gap` px outside each
 *  side, and its corners), and the handle's own centre. */
export function aroundHandle(box: { x: number; y: number; w: number; h: number }, gap = 3) {
  const cx = box.x + box.w / 2;
  const cy = box.y + box.h / 2;
  return {
    centre: { x: cx, y: cy },
    above: { x: cx, y: box.y - gap },
    below: { x: cx, y: box.y + box.h + gap },
    left: { x: box.x + 2, y: cy },
    right: { x: box.x + box.w - 2, y: cy },
  };
}
