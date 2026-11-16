// A row whose reveal frame throws stops only itself: the other replies on the shared reveal clock
// keep revealing (chat-instant-under-load.md piece 4).
import { afterEach, expect, test } from "bun:test";
import { revealClock, revealFrames } from "./revealedMarkdownModel";

const saved = { ...revealFrames };
afterEach(() => {
  for (const tick of [...revealClock.rows]) revealClock.remove(tick);
  Object.assign(revealFrames, saved);
});

test("a row whose frame throws leaves the rows after it on the clock", () => {
  const queued: ((now: number) => void)[] = [];
  revealFrames.request = (callback) => queued.push(callback);
  revealFrames.cancel = () => {};
  let later = 0;
  const broken = (): boolean => {
    throw new Error("broken row");
  };
  const next = (): boolean => {
    later += 1;
    return later < 3;
  };
  revealClock.add(broken);
  revealClock.add(next);
  expect(() => queued.shift()!(16)).toThrow("broken row");
  expect(revealClock.rows.has(next)).toBe(true);
  revealClock.remove(broken);
  // The clock asks for another frame for the rows still revealing, and runs them to their end.
  for (let now = 32; queued.length && now < 1_000; now += 16) queued.shift()!(now);
  expect(later).toBe(3);
  expect(revealClock.rows.size).toBe(0);
});
