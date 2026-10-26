import { expect, test } from "bun:test";
import { cutBetween } from "./lineCut";

test.each([
  [[], 160, 160],
  [[{ top: 150.25, bottom: 170 }], 160, 150.25],
  [
    [
      { top: 140, bottom: 160 },
      { top: 155, bottom: 180 },
    ],
    160,
    140,
  ],
  [[{ top: 0, bottom: 400 }], 160, 0],
  [
    [
      { top: 0, bottom: 159.9 },
      { top: 160.1, bottom: 180 },
    ],
    160,
    160,
  ],
] as const)("cut avoids crossing rendered boxes: %j", (spans, limit, expected) => {
  expect(cutBetween(spans, limit)).toBe(expected);
  expect(cutBetween([...spans].reverse(), limit)).toBe(expected);
});
