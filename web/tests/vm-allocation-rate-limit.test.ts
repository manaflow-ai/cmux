import { describe, expect, test } from "bun:test";
import { enforceVmAllocationRateLimit } from "../services/vms/allocationRateLimit";

function request(): Request {
  return new Request("https://cmux.test/api/vm", { method: "POST" });
}

describe("Cloud VM allocation rate limit", () => {
  test("does not require a Vercel firewall rule outside Vercel", async () => {
    const response = await enforceVmAllocationRateLimit({
      request: request(),
      route: "vm.create",
      billingTeamId: "team-1",
      isVercel: false,
    });
    expect(response).toBeNull();
  });

  test("fails closed on Vercel when the allocation rule is unset", async () => {
    const response = await enforceVmAllocationRateLimit({
      request: request(),
      route: "vm.create",
      billingTeamId: "team-1",
      ruleId: "",
      isVercel: true,
    });
    expect(response?.status).toBe(503);
    expect(await response?.json()).toMatchObject({ error: "rate_limit_unavailable" });
  });

  test("fails closed when Vercel cannot find or check the configured rule", async () => {
    for (const check of [
      async () => ({ rateLimited: false, error: "not-found" }),
      async () => { throw new Error("firewall unavailable"); },
    ]) {
      const response = await enforceVmAllocationRateLimit({
        request: request(),
        route: "vm.create",
        billingTeamId: "team-1",
        ruleId: "rule-allocation",
        check,
        isVercel: true,
      });
      expect(response?.status).toBe(503);
      expect(await response?.json()).toMatchObject({ error: "rate_limit_unavailable" });
    }
  });

  test("partitions by billing team and gives limited clients a retry delay", async () => {
    const calls: unknown[] = [];
    const response = await enforceVmAllocationRateLimit({
      request: request(),
      route: "vm.snapshot",
      billingTeamId: "team-1",
      ruleId: "rule-allocation",
      isVercel: true,
      check: async (...args) => {
        calls.push(args);
        return { rateLimited: true };
      },
    });
    expect(calls).toEqual([[
      "rule-allocation",
      { request: expect.any(Request), rateLimitKey: "vm-allocation:team-1" },
    ]]);
    expect(response?.status).toBe(429);
    expect(response?.headers.get("retry-after")).toBe("60");
    expect(await response?.json()).toMatchObject({
      error: "vm_allocation_rate_limited",
      retryAfterSeconds: 60,
    });
  });
});
