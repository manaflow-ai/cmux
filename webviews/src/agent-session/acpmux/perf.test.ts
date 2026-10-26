import { expect, test } from "bun:test";
import { typingSummary } from "./perf";

const samples = [
  { frame: 6.123, paint: 7.456 },
  { frame: 8.2, paint: 9.9 },
];

test("typingSummary gives the distributions and, with raw, every key's times", () => {
  const plain = typingSummary(samples);
  expect(plain.keys).toBe(2);
  expect(plain).not.toHaveProperty("to_frame_ms");
  expect(typingSummary(samples, true)).toMatchObject({
    keys: 2,
    to_frame_ms: [6.12, 8.2],
    to_paint_ms: [7.46, 9.9],
  });
});
