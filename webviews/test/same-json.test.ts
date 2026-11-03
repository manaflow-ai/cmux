// sameJson (src/agent-session/acpmux/sameJson.ts): tells a summary acpmux sends again unchanged from a change.
import { expect, test } from "bun:test";
import { sameJson } from "../src/agent-session/acpmux/sameJson";

test("equal JSON values are the same whatever their key order", () => {
  expect(sameJson({ a: 1, b: [1, { c: "x" }], d: null }, { d: null, b: [1, { c: "x" }], a: 1 })).toBe(true);
  expect(sameJson({ a: 1, gone: undefined }, { a: 1 })).toBe(true);
  expect(sameJson([], [])).toBe(true);
});

test("any difference is a change", () => {
  expect(sameJson({ a: 1 }, { a: 2 })).toBe(false);
  expect(sameJson({ a: 1 }, { a: 1, b: 0 })).toBe(false);
  expect(sameJson({ a: [1, 2] }, { a: [2, 1] })).toBe(false);
  expect(sameJson({ a: {} }, { a: [] })).toBe(false);
  expect(sameJson({ a: null }, { a: {} })).toBe(false);
  expect(sameJson({ a: "1" }, { a: 1 })).toBe(false);
});
