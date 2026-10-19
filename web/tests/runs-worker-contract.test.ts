import { describe, expect, test } from "bun:test";
import {
  canApplyRunAttemptMutation,
  isRunAttemptLeaseActive,
  runAttemptTransitionDecision,
} from "../services/runs/worker-contract";

const NOW = new Date("2026-10-18T06:00:00.000Z");

function lease(overrides: Partial<Parameters<typeof isRunAttemptLeaseActive>[0]> = {}) {
  return {
    leaseId: "lease-a",
    expectedLeaseId: "lease-a",
    leaseUntil: new Date(NOW.getTime() + 30_000),
    now: NOW,
    ...overrides,
  };
}

describe("Run attempt worker fencing", () => {
  test("accepts the current unexpired lease and rejects the exact expiry boundary", () => {
    expect(isRunAttemptLeaseActive(lease())).toBe(true);
    expect(isRunAttemptLeaseActive(lease({ leaseUntil: new Date(NOW.getTime()) }))).toBe(false);
    expect(isRunAttemptLeaseActive(lease({ leaseUntil: new Date(NOW.getTime() - 1) }))).toBe(false);
  });

  test("fences a stale worker even when its token is otherwise well formed", () => {
    expect(canApplyRunAttemptMutation({
      status: "running",
      ...lease({ leaseId: "lease-old", expectedLeaseId: "lease-new" }),
    })).toBe(false);
    expect(canApplyRunAttemptMutation({
      status: "succeeded",
      ...lease(),
    })).toBe(false);
  });

  test("classifies duplicate terminal callbacks as replay and does not reapply them", () => {
    expect(runAttemptTransitionDecision({ currentStatus: "running", requestedStatus: "succeeded", ...lease() })).toBe("apply");
    expect(runAttemptTransitionDecision({ currentStatus: "succeeded", requestedStatus: "succeeded", ...lease() })).toBe("replay");
    expect(runAttemptTransitionDecision({ currentStatus: "failed", requestedStatus: "succeeded", ...lease() })).toBe("fenced");
  });
});
