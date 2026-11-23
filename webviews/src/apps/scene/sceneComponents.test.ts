import { expect, test } from "bun:test";
import { chartGeometry, chartValues, componentState, componentVariant, statDeltaColor } from "./sceneComponents";

test("a line spans the values' range inset by half its stroke, and a flat or single series runs across the middle", () => {
  const line = chartGeometry([0, 10, 5], "line", 100, 32);
  expect(line).toEqual({
    kind: "line",
    points: [
      [0, 31.25],
      [50, 0.75],
      [100, 16],
    ],
  });
  expect(chartGeometry([4, 4], "line", 100, 32)).toEqual({
    kind: "line",
    points: [
      [0, 16],
      [100, 16],
    ],
  });
  expect(chartGeometry([7], "line", 100, 32)).toEqual({
    kind: "line",
    points: [
      [0, 16],
      [100, 16],
    ],
  });
});

test("bars stand on zero: they rise above it, hang below it, and the range always holds zero", () => {
  const up = chartGeometry([1, 2], "bar", 100, 32);
  if (up.kind !== "bar") throw new Error("bars");
  expect(up.bars.map((b) => [b.x, b.y, b.width, b.height])).toEqual([
    [5, 16, 40, 16],
    [55, 0, 40, 32],
  ]);
  const mixed = chartGeometry([2, -2], "bar", 100, 32);
  if (mixed.kind !== "bar") throw new Error("bars");
  expect(mixed.bars.map((b) => [b.y, b.height])).toEqual([
    [0, 16],
    [16, 16],
  ]);
  const zeros = chartGeometry([0, 0], "bar", 100, 32);
  if (zeros.kind !== "bar") throw new Error("bars");
  expect(zeros.bars.map((b) => b.height)).toEqual([0, 0]);
});

test("values are finite numbers, the last 64", () => {
  expect(chartValues([1, Number.NaN, "2", 3, Infinity])).toEqual([1, 3]);
  expect(chartValues(Array.from({ length: 70 }, (_, i) => i))).toHaveLength(64);
  expect(chartValues("nope")).toEqual([]);
});

test("variants and states are the Rust table's: unknown and non-components draw standard and no state", () => {
  expect(componentVariant("Badge", "prominent")).toBe("prominent");
  expect(componentVariant("Badge", "loud")).toBe("standard");
  expect(componentVariant("Toggle", "prominent")).toBe("standard");
  expect(componentState("Toggle", "loading")).toBe("loading");
  expect(componentState("VStack", "loading")).toBeUndefined();
  expect(componentState("Row", "busy")).toBeUndefined();
});

test("a delta is success when its trend is the good one, danger when not, secondary when flat", () => {
  expect(statDeltaColor("up", undefined)).toBe("success");
  expect(statDeltaColor("up", "down")).toBe("danger");
  expect(statDeltaColor("down", "down")).toBe("success");
  expect(statDeltaColor("flat", "up")).toBe("secondary");
});
