// The send token capped for the slim arm (composerStates.css SEND-SLIM) reads as its least time, so
// the script clocks that read it (sendMorph.ts, followGlide.ts) run on the cap the CSS runs on.
import { expect, test } from "bun:test";
import { cssTimeMs } from "./fold";

test("a CSS time and a min() of times", () => {
  expect(cssTimeMs("180ms")).toBe(180);
  expect(cssTimeMs(".2s")).toBe(200);
  expect(cssTimeMs("min(180ms, 120ms)")).toBe(120);
  expect(cssTimeMs(" min(0ms, 120ms) ")).toBe(0);
  expect(cssTimeMs("min(90ms,120ms)")).toBe(90);
  expect(cssTimeMs("min(var(--x), 120ms)")).toBeUndefined();
  expect(cssTimeMs("auto")).toBeUndefined();
});
