import { describe, expect, test } from "bun:test";
import {
  canApplyRunAttemptMutation,
  isRunAttemptLeaseActive,
  runAttemptTransitionDecision,
} from "../services/runs/worker-contract";
import {
  isRunCloudOperationPending,
  RUN_CLOUD_CREATE_PENDING_LIMIT_MS,
  RunCloudOperationPending,
  runCloudCreatePendingExpired,
} from "../services/runs/cloudClientContract";

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
  test("treats the Cloud VM create-in-progress response as retryable state", () => {
    expect(isRunCloudOperationPending({ error: "vm_create_in_progress" })).toBe(true);
    expect(isRunCloudOperationPending({ error: "vm_create_failed" })).toBe(false);
    expect(isRunCloudOperationPending(null)).toBe(false);
    expect(new RunCloudOperationPending().code).toBe("vm_create_in_progress");
  });

  test("stops retrying an in-progress Cloud VM create after the ceiling", () => {
    const startedAt = new Date(NOW.getTime() - RUN_CLOUD_CREATE_PENDING_LIMIT_MS);
    expect(runCloudCreatePendingExpired({ startedAt: new Date(NOW.getTime() - 60_000), now: NOW })).toBe(false);
    expect(runCloudCreatePendingExpired({ startedAt: new Date(startedAt.getTime() + 1), now: NOW })).toBe(false);
    expect(runCloudCreatePendingExpired({ startedAt, now: NOW })).toBe(true);
    // No recorded start means no evidence the create is alive.
    expect(runCloudCreatePendingExpired({ startedAt: null, now: NOW })).toBe(true);
    // The ceiling outlasts /api/vm's 960s maxDuration, so a live create is never cut off.
    expect(RUN_CLOUD_CREATE_PENDING_LIMIT_MS).toBeGreaterThan(960_000);
  });

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
