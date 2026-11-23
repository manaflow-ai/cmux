import { expect, test } from "bun:test";
import { RailRevealIntent, REVEAL_DWELL, type RevealClock } from "./railIntent";

// A selection drag along the rail's edge at a narrow width never reveals or captures the rail
// (Leo, 2026-11-22: "there's a lot of awkwardness when you try to e.g. copy text along this area").

function fake() {
  let now = 0;
  const jobs = new Map<number, { at: number; run: () => void }>();
  let next = 0;
  const clock: RevealClock = {
    set: (run, ms) => {
      jobs.set(++next, { at: now + ms, run });
      return next;
    },
    clear: (handle) => void jobs.delete(handle as number),
  };
  const advance = (ms: number) => {
    now += ms;
    for (const [id, job] of [...jobs]) {
      if (job.at <= now) {
        jobs.delete(id);
        job.run();
      }
    }
  };
  return { clock, advance };
}

function setup() {
  const { clock, advance } = fake();
  const log = { reveals: 0, hides: 0 };
  const intent = new RailRevealIntent(
    () => log.reveals++,
    () => log.hides++,
    clock,
  );
  return { intent, advance, log };
}

test("a selection drag that starts in the text and runs along the edge strip never reveals", () => {
  const { intent, advance, log } = setup();
  intent.pressOutside();
  intent.enter(1);
  for (let step = 0; step < 20; step++) {
    advance(50);
    intent.move(1);
  }
  advance(REVEAL_DWELL * 4);
  expect(log.reveals).toBe(0);
});

test("a drag that ends on the strip does not reveal until the pointer moves and rests", () => {
  const { intent, advance, log } = setup();
  intent.pressOutside();
  intent.enter(1);
  intent.release();
  advance(REVEAL_DWELL * 4);
  expect(log.reveals).toBe(0);
  intent.move(0);
  advance(REVEAL_DWELL);
  expect(log.reveals).toBe(1);
});

test("a press outside hides a revealed rail so the drag keeps the text", () => {
  const { intent, advance, log } = setup();
  intent.enter(0);
  advance(REVEAL_DWELL);
  expect(log.reveals).toBe(1);
  intent.pressOutside();
  expect(log.hides).toBe(1);
  expect(intent.pressingText).toBe(true);
});

test("a pointer sweeping past the strip never reveals", () => {
  const { intent, advance, log } = setup();
  intent.enter(0);
  advance(60);
  intent.leave();
  advance(REVEAL_DWELL * 4);
  expect(log.reveals).toBe(0);
});

test("a pointer moving on the strip reveals once it rests", () => {
  const { intent, advance, log } = setup();
  intent.enter(0);
  for (let step = 0; step < 6; step++) {
    advance(REVEAL_DWELL - 20);
    intent.move(0);
  }
  expect(log.reveals).toBe(0);
  advance(REVEAL_DWELL);
  expect(log.reveals).toBe(1);
});
