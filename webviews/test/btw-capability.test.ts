import { expect, test } from "bun:test";
import { BTW_INLINE, supportsBtwInline } from "../src/agent-session/acpmux/btwCapability";

test("inline btw capability gates the new reply shape", () => {
  expect(BTW_INLINE).toBe("btw-inline-v1");
  expect(supportsBtwInline(new Set([BTW_INLINE]))).toBe(true);
  expect(supportsBtwInline(new Set(["acpmux-v1"]))).toBe(false);
  expect(supportsBtwInline(undefined)).toBe(false);
});
