import { describe, expect, mock, test } from "bun:test";

const request = new Request("https://cmux.test/api/runs", {
  method: "POST",
  headers: { "content-type": "application/json", "idempotency-key": "run-key" },
});

const run = {
  userId: "user-run",
  billingTeamId: "team-run",
  idempotencyKey: "run-key",
  requestDigest: "sha256:fixture",
  source: { repository: "manaflow-ai/cmux", commit: "a".repeat(40) },
  recipe: "parallel-review",
  provider: "cloud-vm" as const,
  desiredAttempts: 32,
};

describe("Run create allocation admission", () => {
  test("allocation refusal precedes persistence for a 32-attempt Run", async () => {
    // Import inside the test so loading this file cannot preempt another
    // suite's auth mocks through allocationRateLimit -> routeHelpers.
    const { createRunWithAllocationAdmission } = await import("../services/runs/allocationAdmission");
    const refusal = Response.json({ error: "vm_allocation_rate_limited" }, { status: 429 });
    const check = mock(async () => refusal);
    const persist = mock(async () => { throw new Error("allocation refusal must precede run persistence"); });

    const result = await createRunWithAllocationAdmission(
      { request, billingTeamId: "team-run", run },
      { check, persist },
    );

    expect(result).toEqual({ kind: "limited", response: refusal });
    expect(check).toHaveBeenCalledWith({
      request,
      route: "run.create",
      billingTeamId: "team-run",
      cost: 32,
    });
    expect(persist).not.toHaveBeenCalled();
  });
});
