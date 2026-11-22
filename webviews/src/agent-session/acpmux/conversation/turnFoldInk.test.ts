// A row that leaves a fold while it is still fading in drew only part of its ink. Its copy goes on
// from that ink, and a row with almost none gets no copy: copied at full ink, the "Worked for" close
// drew it over its neighbour (Leo, 2026-11-21: "it was in the agent chat gui the text goes atop one
// another"). The fold reads that ink off the row's reveal (`revealInk`) and off its style (`drawnInk`).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { drawnInk, HIDDEN_INK, revealInk } from "./turnFold";

function animation(frames: Keyframe[], progress: number | null): Animation {
  const effect = {
    getKeyframes: () => frames.map((frame) => ({ ...frame, computedOffset: 0, easing: "linear", composite: "auto" })),
    getComputedTiming: () => ({ progress }),
  };
  return { effect } as unknown as Animation;
}

test("a reveal's ink is its eased progress, and the full ink once it ends", () => {
  const fade = [{ opacity: 0 }, { opacity: 1 }];
  expect(revealInk([animation(fade, 0)])).toBe(0);
  expect(revealInk([animation(fade, 0.3)])).toBeCloseTo(0.3);
  expect(revealInk([animation(fade, 1.4)])).toBe(1);
  // Ended (no progress) or no reveal at all: the row drew its full ink.
  expect(revealInk([animation(fade, null)])).toBe(1);
  expect(revealInk([])).toBe(1);
  // A move is not a reveal: only an animation of opacity counts.
  expect(revealInk([animation([{ transform: "none" }, { transform: "none" }], 0.1), animation(fade, 0.2)])).toBeCloseTo(
    0.2,
  );
  expect(revealInk([animation(fade, 0.2)]) < HIDDEN_INK).toBe(true);
});

test("a row's drawn ink is its computed opacity, full when it has none", () => {
  const { document } = new JSDOM("<!doctype html><body></body>").window;
  const row = document.createElement("div");
  document.body.append(row);
  expect(drawnInk(row)).toBe(1);
  row.style.opacity = "0.25";
  expect(drawnInk(row)).toBeCloseTo(0.25);
  expect(drawnInk(row) < HIDDEN_INK).toBe(true);
});
