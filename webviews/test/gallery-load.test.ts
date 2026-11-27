// The load axis's main-thread taker (frame/load.ts): it spends its frame share and long tasks, and
// stops, on its stop or on pagehide, with nothing left scheduled.
import { expect, test } from "bun:test";
import { LOAD_PROFILES, startGalleryLoad } from "../src/gallery/frame/load";

function fakeWindow() {
  const frames = new Map<number, () => void>();
  const intervals = new Map<number, () => void>();
  const listeners = new Map<string, () => void>();
  let next = 1;
  const win = {
    requestAnimationFrame: (callback: () => void) => (frames.set(next, callback), next++),
    cancelAnimationFrame: (id: number) => void frames.delete(id),
    setInterval: (callback: () => void) => (intervals.set(next, callback), next++),
    clearInterval: (id: number) => void intervals.delete(id),
    addEventListener: (type: string, callback: () => void) => void listeners.set(type, callback),
    removeEventListener: (type: string) => void listeners.delete(type),
  } as unknown as Window;
  const runFrame = () => {
    const [[id, callback]] = [...frames];
    frames.delete(id!);
    callback!();
  };
  return { win, frames, intervals, listeners, runFrame };
}

test("no load schedules nothing", () => {
  const fake = fakeWindow();
  startGalleryLoad(undefined, fake.win);
  startGalleryLoad("none", fake.win);
  expect(fake.frames.size + fake.intervals.size).toBe(0);
  expect(fake.win.cmuxGalleryLoad).toBeUndefined();
});

test("busy takes its share of each frame and its long task, then stops on pagehide", () => {
  const fake = fakeWindow();
  startGalleryLoad("busy", fake.win);
  fake.runFrame();
  fake.runFrame();
  const stats = fake.win.cmuxGalleryLoad!;
  expect(stats.frames).toBe(2);
  expect(stats.blockedMs).toBeGreaterThanOrEqual(2 * LOAD_PROFILES.busy.frameMs);
  [...fake.intervals.values()][0]!();
  expect(stats.longTasks).toBe(1);
  expect(stats.blockedMs).toBeGreaterThanOrEqual(2 * LOAD_PROFILES.busy.frameMs + LOAD_PROFILES.busy.longTaskMs);
  fake.listeners.get("pagehide")!();
  expect(fake.frames.size + fake.intervals.size + fake.listeners.size).toBe(0);
});

test("its stop clears what it scheduled", () => {
  const fake = fakeWindow();
  const stop = startGalleryLoad("saturated", fake.win);
  stop();
  stop();
  expect(fake.frames.size + fake.intervals.size + fake.listeners.size).toBe(0);
});
