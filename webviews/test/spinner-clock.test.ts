// SYNCED-SPINNERS (user 2026-10-20: "make sure spinners are synced and spinning in the same
// direction"): every page spinner's phase is Unix time mod its period, the time base the native
// spinners use (CmuxNextDesign SpinnerClock), so spinners started at different moments line up.
import { expect, test } from "bun:test";
import { alignSpinner, spinnerStartTime, SPINNER_KEYFRAMES, type SpinnerAnimation } from "../src/ui/spinnerClock";

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

test("a paused loop is left alone: a start time would play it past its animation-play-state", () => {
  const timing = { getTiming: () => ({ duration: period }) };
  const paused: SpinnerAnimation = {
    animationName: SPINNER_KEYFRAMES,
    playState: "paused",
    startTime: null,
    effect: timing,
  };
  expect(alignSpinner(paused, 2_000, 1_760_000_000_050)).toBe(false);
  expect(paused.startTime).toBeNull();
});
