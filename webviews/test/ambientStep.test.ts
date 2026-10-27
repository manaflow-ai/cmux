// AMBIENT-STEP (p14-energy-126): under `data-cmux-ambient="step"` a page's ambient loops are paused
// and seeked to the shared phase on each tick of the page clock's ambient granularity: one aligned
// timer for every loop, AMBIENT_STEPS_PER_SECOND wakes a second, none while the page is hidden or no
// loop is held, and every loop handed back to the display's rate when stepping turns off.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";
import {
  AMBIENT_ATTRIBUTE,
  AMBIENT_EXEMPT_KEYFRAMES,
  AMBIENT_STEP,
  type AmbientAnimation,
  AmbientStepper,
  ENGINE_ATTRIBUTE,
  WEBKIT_ENGINE,
  ambientPhase,
  installAmbientStep,
} from "../src/ui/ambientStep";
import { PageLifecycle } from "../src/pages/shared/pageLifecycle";
import { AMBIENT_STEPS_PER_SECOND, type ClockTimers, PageClock, clockFloor, clockPeriodMs } from "../src/ui/pageClock";
import { FakeClockTimers, FakeVisibilityDocument, fakePage } from "./support/fakePageClock";

const STEP = clockPeriodMs("ambient");

/** A CSS animation as the stepper sees it: its name, period, iteration count, play state and element. */
class FakeLoop implements AmbientAnimation {
  playState = "running";
  currentTime: number | null = 0;
  pauses = 0;
  plays = 0;
  private start: number | null = 0;
  readonly element = { isConnected: true };
  readonly effect;

  constructor(
    readonly animationName: string,
    period: number,
    iterations = Number.POSITIVE_INFINITY,
  ) {
    this.effect = { target: this.element, getTiming: () => ({ duration: period, iterations }) };
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

  // Web Animations: play() resumes a paused animation from its current time.
  play(): void {
    this.plays += 1;
    this.playState = "running";
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
    const loops = [
      new FakeLoop("cv-enter", 180, 1),
      new FakeLoop("cmux-spin", 0),
      new FakeLoop("nt-widget-wiggle", 280),
    ];
    for (const loop of loops) {
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

  test("a loop with its own phase goes on from where it was, one step a tick, and plays on from there", () => {
    const { timers, state, stepper } = makeStepper();
    const writing = new FakeLoop("hc-writing", 1400);
    writing.currentTime = 300;
    expect(stepper.hold(writing)).toBe(true);
    expect(writing.playState).toBe("paused");
    expect(writing.currentTime).toBe(300);
    timers.advance(STEP * 3);
    // Each tick draws its local time on the step: three steps later, from the step it was held on.
    const held = clockFloor(timers.now() - STEP * 3, "ambient");
    expect(writing.currentTime).toBeCloseTo(300 + clockFloor(timers.now(), "ambient") - held, 6);
    state.on = false;
    timers.advance(STEP);
    expect(writing.plays).toBe(1);
    expect(writing.playState).toBe("running");
    expect(timers.live).toBe(0);
  });

  test("holding a held loop again keeps its time", () => {
    const { timers, stepper } = makeStepper();
    const mascot = new FakeLoop("acpmux-chief-mascot-float", 2800);
    mascot.currentTime = 1000;
    stepper.hold(mascot);
    timers.advance(STEP * 2);
    const drawn = mascot.currentTime;
    expect(stepper.hold(mascot)).toBe(true);
    expect(mascot.currentTime).toBe(drawn);
    expect(stepper.size).toBe(1);
  });
});

describe("ambient step engines", () => {
  /** A document root with `attributes` that records what the stepper installs on it. */
  function fakeDocument(attributes: Record<string, string>, animations: AmbientAnimation[] = []) {
    const listeners: string[] = [];
    const doc = {
      documentElement: { getAttribute: (name: string) => attributes[name] ?? null },
      addEventListener: (type: string) => listeners.push(type),
      getAnimations: () => animations,
      defaultView: null,
    };
    return { doc: doc as unknown as Document, listeners };
  }

  test("a WebKit page never steps: its loops stay with the render server and no listener is added", () => {
    const { clock, timers } = fakePage(1_700_000_000_123);
    const spin = new FakeLoop("cmux-spin", 900);
    const { doc, listeners } = fakeDocument({ [AMBIENT_ATTRIBUTE]: AMBIENT_STEP, [ENGINE_ATTRIBUTE]: WEBKIT_ENGINE }, [
      spin,
    ]);
    const stepper = installAmbientStep(doc, clock);
    expect(listeners).toEqual([]);
    expect(stepper.hold(spin)).toBe(false);
    expect(spin.playState).toBe("running");
    expect(timers.live).toBe(0);
  });

  test("a Chromium page steps the loops already running", () => {
    const { clock, timers } = fakePage(1_700_000_000_123);
    const spin = new FakeLoop("cmux-spin", 900);
    const { doc, listeners } = fakeDocument({ [AMBIENT_ATTRIBUTE]: AMBIENT_STEP }, [spin]);
    const stepper = installAmbientStep(doc, clock);
    expect(listeners).toEqual(["animationstart"]);
    expect(stepper.size).toBe(1);
    expect(spin.playState).toBe("paused");
    expect(timers.live).toBe(1);
  });
});

describe("every ambient loop in the pages steps", () => {
  const SRC = path.resolve(import.meta.dir, "../src");

  function stylesheets(dir: string, out: string[] = []): string[] {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "gallery") stylesheets(full, out);
      } else if (entry.name.endsWith(".css")) out.push(full);
    }
    return out.sort();
  }

  const sheets = stylesheets(SRC).map((file) => ({
    file: path.relative(SRC, file),
    css: readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, ""),
  }));
  const keyframes = new Set(sheets.flatMap(({ css }) => [...css.matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1]!)));

  /** Each infinite animation of the `animation` shorthands: its keyframes name and stylesheet. */
  const loops = sheets.flatMap(({ file, css }) =>
    [...css.matchAll(/(?:^|[;{\s])animation\s*:([^;{}]*)/g)].flatMap((match) =>
      match[1]!
        .split(/,(?![^(]*\))/)
        .filter((part) => /\binfinite\b/.test(part))
        .map((part) => ({
          file,
          name: part
            .trim()
            .split(/\s+/)
            .find((token) => keyframes.has(token)),
        })),
    ),
  );

  test("the list sees every infinite loop, each with its keyframes", () => {
    const names = new Set(loops.map((loop) => loop.name));
    for (const name of [
      "cmux-spin",
      "cmux-wave",
      "hc-writing",
      "acpmux-mic-wait",
      "nt-player-level",
      "cloud-store-packet",
      "acpmux-chief-mascot-float",
    ]) {
      expect(names).toContain(name);
    }
    expect(loops.filter((loop) => loop.name === undefined)).toEqual([]);
    // The longhand would hide a loop from this list; the stepper still takes it at run time.
    expect(sheets.filter(({ css }) => /animation-iteration-count\s*:\s*infinite/.test(css)).map((s) => s.file)).toEqual(
      [],
    );
  });

  test("each infinite loop is stepped or explicitly exempt", () => {
    const { stepper } = makeStepper();
    const notStepped = loops
      .filter((loop) => !AMBIENT_EXEMPT_KEYFRAMES.has(loop.name!))
      .filter((loop) => !stepper.hold(new FakeLoop(loop.name!, 1000)))
      .map((loop) => `${loop.file}: ${loop.name}`);
    expect(notStepped).toEqual([]);
  });

  test("each exempt loop still exists and is not stepped", () => {
    const { stepper } = makeStepper();
    for (const name of AMBIENT_EXEMPT_KEYFRAMES) {
      expect(loops.map((loop) => loop.name)).toContain(name);
      expect(stepper.hold(new FakeLoop(name, 1000))).toBe(false);
    }
  });
});
