import { describe, expect, it } from "vitest";
import { ATTACH_RECOVERY_STABLE_MS, attachRecoveryDelay } from "../src/lib/attachRecovery";

describe("surface attach recovery", () => {
  it("uses bounded backoff", () => {
    expect([0, 1, 2, 3].map(attachRecoveryDelay)).toEqual([100, 250, 500, null]);
    expect(ATTACH_RECOVERY_STABLE_MS).toBe(5_000);
  });
});
