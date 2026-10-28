import { expect, test } from "bun:test";

test("inline btw capability gates the new reply shape", () => {
  const canInline = (capabilities: ReadonlySet<string> | undefined) => capabilities?.has("btw-inline-v1") === true;
  expect(canInline(new Set(["btw-inline-v1"]))).toBe(true);
  expect(canInline(new Set(["acpmux-v1"]))).toBe(false);
  expect(canInline(undefined)).toBe(false);
});
