// AMBIENT-STEP (p14-energy-126): under `data-cmux-ambient="step"` a page's ambient loops are paused
// and seeked to the shared phase on each tick of the page clock's ambient granularity: one aligned
// timer for every loop, AMBIENT_STEPS_PER_SECOND wakes a second, none while the page is hidden or no
// loop is held, and every loop handed back to the display's rate when stepping turns off.
import { describe, expect, test } from "bun:test";
import { type AmbientAnimation, AmbientStepper, ambientPhase } from "../src/ui/ambientStep";
import { PageLifecycle } from "../src/pages/shared/pageLifecycle";
import { AMBIENT_STEPS_PER_SECOND, type ClockTimers, PageClock, clockFloor, clockPeriodMs } from "../src/ui/pageClock";
import { FakeClockTimers, FakeVisibilityDocument, fakePage } from "./support/fakePageClock";

const STEP = clockPeriodMs("ambient");

/** A CSS animation as the stepper sees it: its name, period, play state and element. */
class FakeLoop implements AmbientAnimation {
  playState = "running";
  currentTime: number | null = 0;
  pauses = 0;
  private start: number | null = 0;
  readonly element = { isConnected: true };
  readonly effect;

  constructor(
    readonly animationName: string,
    period: number,
  ) {
    this.effect = { target: this.element, getTiming: () => ({ duration: period }) };
  }

  get startTime(): number | null {
    return this.start;
  }

  // Web Animations: a resolved start time plays the animation.
  set startTime(value: number | null) {
    this.start = value;
    if (value !== null) this.playState = "running";
  }

  pause(): void {
    this.pauses += 1;
    this.playState = "paused";
  }
}

function makeStepper(start = 1_700_000_000_123, on = true) {
  const page = fakePage(start);
  const state = { on, readAt: 0 };
  const stepper = new AmbientStepper(
    page.clock,
    () => state.on,
    () => {
      state.readAt = page.timers.now();
      return { now: 5_000, origin: state.readAt - 5_000 };
    },
  );
  return { ...page, state, stepper };
}

describe("ambient step", () => {
  test("a held loop is paused on the shared phase of the current step", () => {
    const { timers, stepper } = makeStepper();
    const spin = new FakeLoop("cmux-spin", 900);
    expect(stepper.hold(spin)).toBe(true);
    expect(spin.playState).toBe("paused");
    expect(spin.currentTime).toBe(ambientPhase(clockFloor(timers.now(), "ambient"), 900));
  });

  test("five loops share one timer that wakes 15 times a second, each on a step boundary", () => {
    const { timers, stepper } = makeStepper();
    const loops = [
      new FakeLoop("cmux-spin", 900),
      new FakeLoop("cmux-breathe", 2400),
      new FakeLoop("cmux-shimmer-band", 2400),
      new FakeLoop("cmux-shimmer-lit", 2400),
      new FakeLoop("cmux-wave", 1600),
    ];
    for (const loop of loops) stepper.hold(loop);
    expect(timers.live).toBe(1);
    const armed = timers.armed;
    const seen: number[] = [];
    for (let index = 0; index < AMBIENT_STEPS_PER_SECOND * 2; index += 1) {
      timers.advance(STEP);
      seen.push(loops[0].currentTime ?? -1);
    }
    expect(timers.armed - armed).toBe(AMBIENT_STEPS_PER_SECOND * 2);
    expect(timers.live).toBe(1);
    // Each tick draws the step it lands in, the same instant for every loop.
    const at = clockFloor(timers.now(), "ambient");
    for (const loop of loops) {
      expect(loop.currentTime).toBeCloseTo(ambientPhase(at, Number(loop.effect.getTiming().duration)), 2);
    }
    // Every frame is one step later than the one before (mod the spinner's period).
    for (let index = 1; index < seen.length; index += 1) {
      expect(ambientPhase(seen[index] - seen[index - 1], 900)).toBeCloseTo(STEP, 2);
    }
  });

  test("a hidden page runs no timer and draws nothing; showing it draws the current step", () => {
    const { doc, timers, stepper } = makeStepper();
    const spin = new FakeLoop("cmux-spin", 900);
    stepper.hold(spin);
    doc.hide();
    expect(timers.live).toBe(0);
    const before = spin.currentTime;
    timers.advance(5_000);
    expect(spin.currentTime).toBe(before);
    doc.show();
    expect(spin.currentTime).toBeCloseTo(ambientPhase(clockFloor(timers.now(), "ambient"), 900), 2);
    expect(timers.live).toBe(1);
  });

  test("a loop the stylesheet removed or whose element left is dropped; the last one stops the timer", () => {
    const { timers, stepper } = makeStepper();
    const spin = new FakeLoop("cmux-spin", 900);
    const wave = new FakeLoop("cmux-wave", 1600);
    stepper.hold(spin);
    stepper.hold(wave);
    spin.playState = "idle";
    timers.advance(STEP);
    expect(stepper.size).toBe(1);
    wave.element.isConnected = false;
    timers.advance(STEP);
    expect(stepper.size).toBe(0);
    expect(stepper.ticking).toBe(false);
    expect(timers.live).toBe(0);
  });

  test("a loop something played again is paused on the next step", () => {
    const { timers, stepper } = makeStepper();
    const spin = new FakeLoop("cmux-spin", 900);
    stepper.hold(spin);
    spin.startTime = 12;
    expect(spin.playState).toBe("running");
    timers.advance(STEP);
    expect(spin.playState).toBe("paused");
  });

  test("person-started motion and loops with no period are never held", () => {
    const { timers, stepper } = makeStepper();
    for (const loop of [new FakeLoop("cv-enter", 180), new FakeLoop("cmux-spin", 0)]) {
      expect(stepper.hold(loop)).toBe(false);
      expect(loop.playState).toBe("running");
    }
    expect(timers.live).toBe(0);
  });

  test("off, nothing is held; turning off hands every loop back on the shared phase and stops the timer", () => {
    const off = makeStepper(1_700_000_000_123, false);
    expect(off.stepper.hold(new FakeLoop("cmux-spin", 900))).toBe(false);
    expect(off.timers.live).toBe(0);

    const { timers, state, stepper } = makeStepper();
    const spin = new FakeLoop("cmux-spin", 900);
    stepper.hold(spin);
    state.on = false;
    timers.advance(STEP);
    expect(spin.playState).toBe("running");
    // Phase at the timeline's now (5000) is Unix ms mod the period, as spinnerClock aligns it.
    expect(spin.startTime).toBeCloseTo(5_000 - ambientPhase(state.readAt, 900), 6);
    expect(stepper.size).toBe(0);
    expect(timers.live).toBe(0);
  });

  test("the ambient period is not whole milliseconds, so each wait rounds up and wakes once per step", () => {
    // setTimeout truncates a fractional delay (WebIDL `long`): a wait that is not rounded up fires
    // just before its boundary, lands in the step it was armed in, and wakes again to reach it. The
    // seam waits at least 1 ms, as a browser's clamped zero timeout runs on a later task.
    const inner = new FakeClockTimers(1_700_000_000_000);
    const truncating: ClockTimers = {
      now: () => inner.now(),
      after: (ms, callback) => inner.after(Math.max(1, Math.trunc(ms)), callback),
      cancel: (handle) => inner.cancel(handle),
    };
    const stepper = new AmbientStepper(
      new PageClock(new PageLifecycle(new FakeVisibilityDocument()), truncating),
      () => true,
      () => undefined,
    );
    const spin = new FakeLoop("cmux-spin", 900);
    stepper.hold(spin);
    inner.advance(3000);
    // The first wait, then one per step; a boundary within float error of the end of the run may
    // fall on either side of it.
    expect(inner.armed).toBeGreaterThanOrEqual(AMBIENT_STEPS_PER_SECOND * 3);
    expect(inner.armed).toBeLessThanOrEqual(AMBIENT_STEPS_PER_SECOND * 3 + 1);
  });
});
