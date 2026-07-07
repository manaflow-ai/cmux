import { describe, expect, test } from "bun:test";

import { ensureVmTrialStarted, type VmTrialMetadataUser } from "../services/vms/proGate";

function fakeUser(metadata: unknown) {
  const calls: Array<{ clientReadOnlyMetadata: Record<string, unknown> }> = [];
  const user: VmTrialMetadataUser = {
    clientReadOnlyMetadata: metadata,
    update(input) {
      calls.push(input);
      return Promise.resolve(undefined);
    },
  };
  return { user, calls };
}

describe("ensureVmTrialStarted", () => {
  test("writes the start timestamp on first call and returns it", async () => {
    const { user, calls } = fakeUser({ cmuxPlan: "free" });
    const now = "2026-07-07T00:00:00.000Z";
    const result = await ensureVmTrialStarted(user, now);
    expect(result).toBe(now);
    expect(calls.length).toBe(1);
    expect(calls[0].clientReadOnlyMetadata).toEqual({
      cmuxPlan: "free",
      cmuxVmTrialStartedAt: now,
    });
  });

  test("is idempotent: never overwrites an existing start (no reset by retrying)", async () => {
    const original = "2026-07-01T00:00:00.000Z";
    const { user, calls } = fakeUser({ cmuxVmTrialStartedAt: original });
    const result = await ensureVmTrialStarted(user, "2026-07-07T00:00:00.000Z");
    expect(result).toBe(original);
    expect(calls.length).toBe(0);
  });

  test("handles missing/invalid metadata by starting fresh", async () => {
    const { user, calls } = fakeUser(null);
    const now = "2026-07-07T00:00:00.000Z";
    await ensureVmTrialStarted(user, now);
    expect(calls[0].clientReadOnlyMetadata).toEqual({ cmuxVmTrialStartedAt: now });
  });
});
