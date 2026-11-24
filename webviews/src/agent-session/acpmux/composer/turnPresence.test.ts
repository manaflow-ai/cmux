// The page's copy of the Stop presence model against the corpus Rust's runs (cmux-motion
// tests/turn_presence_cases.rs), so the two cannot drift apart.
import { expect, test } from "bun:test";
import corpus from "../../../../../cmux-tui/crates/cmux-motion/tests/cases/turn_presence.json";
import { DWELL_MS, HOLD_MS, LINGER_MS, TurnPresence } from "./turnPresence";

test("the page's Stop presence uses the corpus's timings", () => {
  const page: Record<string, number> = { dwell: DWELL_MS, linger: LINGER_MS, hold: HOLD_MS };
  expect(page).toEqual({
    dwell: corpus.dwellMs,
    linger: corpus.lingerMs,
    hold: corpus.holdMs,
  });
});

for (const item of corpus.cases)
  test(`Stop presence: ${item.name}`, () => {
    const model = new TurnPresence(item.start, 0);
    for (const step of item.steps as Array<{
      at: number;
      running?: boolean;
      immediate?: boolean;
      shown: boolean;
      pulses: number;
      wake: number | null;
    }>) {
      if (step.running === undefined) model.advance(step.at);
      else model.set(step.running, step.at, step.immediate === true);
      expect({ at: step.at, shown: model.shown, pulses: model.pulses, wake: model.nextWake() ?? null }).toEqual({
        at: step.at,
        shown: step.shown,
        pulses: step.pulses,
        wake: step.wake,
      });
    }
  });
