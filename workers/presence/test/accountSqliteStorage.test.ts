import { expect, test } from "bun:test";
import { expiredBefore, isPayloadWithinQuota, retentionAlarmAt } from "../src/accountSqliteStorage";

test("expiry functions reject corrupt timestamps before issuing SQL", () => {
  for (const value of [-1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER]) {
    expect(() => expiredBefore(value)).toThrow();
    expect(() => retentionAlarmAt(value)).toThrow();
  }
});
test("payload validation rejects non-integer and negative sizes", () => {
  for (const size of [-1, NaN, Infinity, 1.5, 65_537]) expect(isPayloadWithinQuota(size)).toBe(false);
  expect(isPayloadWithinQuota(0)).toBe(true);
  expect(isPayloadWithinQuota(65_536)).toBe(true);
});
