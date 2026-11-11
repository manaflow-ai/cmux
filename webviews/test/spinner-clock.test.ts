// SYNCED-SPINNERS (user 2026-10-20: "make sure spinners are synced and spinning in the same
// direction"): every page spinner's phase is Unix time mod its period, the time base the native
// spinners use (CmuxNextDesign SpinnerClock), so spinners started at different moments line up.
import { expect, test } from "bun:test";
import {
  alignSpinner,
  cssTimeMs,
  spinnerStartTime,
  SPINNER_KEYFRAMES,
  type SpinnerAnimation,
} from "../src/ui/spinnerClock";

const period = 900;

function phaseAt(startTime: number, timelineNow: number): number {
  return (((timelineNow - startTime) % period) + period) % period;
}

test("a spinner's phase is Unix time mod its period", () => {
  const origin = 1_760_000_000_123; // performance.timeOrigin: Unix ms at timeline 0
  const now = 5_000;
  const start = spinnerStartTime(now, origin, period);
  expect(phaseAt(start, now)).toBeCloseTo((origin + now) % period, 6);
  expect(now - start).toBeGreaterThanOrEqual(0);
  expect(now - start).toBeLessThan(period);
});

test("two spinners started apart, in two documents, share one phase", () => {
  // Two pages whose timelines started 3.634 s apart; each spinner starts at its own moment.
  const firstOrigin = 1_760_000_000_000;
  const secondOrigin = 1_760_000_003_634;
  const first = spinnerStartTime(1_000, firstOrigin, period);
  const second = spinnerStartTime(350, secondOrigin, period);
  // At one Unix moment both sit at the same angle.
  const unix = 1_760_000_005_000;
  const firstPhase = phaseAt(first, unix - firstOrigin);
  const secondPhase = phaseAt(second, unix - secondOrigin);
  expect(firstPhase).toBeCloseTo(secondPhase, 6);
});

test("only the shared keyframes are aligned, with their own duration", () => {
  const timing = (duration: number) => ({ getTiming: () => ({ duration }) });
  const spinner: SpinnerAnimation = { animationName: SPINNER_KEYFRAMES, startTime: null, effect: timing(period) };
  const other: SpinnerAnimation = { animationName: "cv-enter", startTime: null, effect: timing(180) };
  expect(alignSpinner(spinner, 2_000, 1_760_000_000_050)).toBe(true);
  expect(alignSpinner(other, 2_000, 1_760_000_000_050)).toBe(false);
  expect(other.startTime).toBeNull();
  expect(phaseAt(spinner.startTime as number, 2_000)).toBeCloseTo((1_760_000_000_050 + 2_000) % period, 6);
});

test("a loop whose delay was its phase is aligned with the delay taken out; another keeps its offset", () => {
  const origin = 1_760_000_000_050;
  const now = 2_000;
  const target = (phased: boolean) => ({ closest: () => (phased ? ({} as Element) : null) }) as unknown as Element;
  const loop = (phased: boolean): SpinnerAnimation => ({
    animationName: SPINNER_KEYFRAMES,
    startTime: null,
    effect: { getTiming: () => ({ duration: period, delay: -300 }), target: target(phased) },
  });
  const phased = loop(true);
  const offset = loop(false);
  alignSpinner(phased, now, origin);
  alignSpinner(offset, now, origin);
  // Active time is (now - startTime) - delay: the phased loop sits on the clock, the other 300 ms past it.
  const active = (each: SpinnerAnimation) => (((now - (each.startTime as number) + 300) % period) + period) % period;
  expect(active(phased)).toBeCloseTo((origin + now) % period, 6);
  expect(active(offset)).toBeCloseTo((((origin + now) % period) + 300) % period, 6);
});

test("a phased loop whose delay is past its phase starts before now, on the same phase", () => {
  // The clock's phase here is 50 ms; a delay of -700 ms would put the start 650 ms after now, where the
  // loop draws at progress 0 until then.
  const origin = 1_760_000_000_000 - ((1_760_000_000_000 % period) - 50);
  const now = 0;
  const loop: SpinnerAnimation = {
    animationName: SPINNER_KEYFRAMES,
    startTime: null,
    effect: {
      getTiming: () => ({ duration: period, delay: -700 }),
      target: { closest: () => ({}) } as unknown as Element,
    },
  };
  alignSpinner(loop, now, origin);
  expect(loop.startTime as number).toBeLessThanOrEqual(now);
  expect((((now - (loop.startTime as number) + 700) % period) + period) % period).toBeCloseTo(
    (origin + now) % period,
    6,
  );
});

test("a CSS time reads in ms", () => {
  expect(cssTimeMs("2.8s")).toBe(2800);
  expect(cssTimeMs(" 900ms ")).toBe(900);
  expect(cssTimeMs("")).toBeUndefined();
  expect(cssTimeMs("0s")).toBeUndefined();
  expect(cssTimeMs("var(--x)")).toBeUndefined();
});
