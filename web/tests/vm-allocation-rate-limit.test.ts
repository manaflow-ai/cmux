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
    expect(calls).toHaveLength(1);
    const [ruleId, options] = calls[0] as [string, { request: Request; rateLimitKey: string; signal: AbortSignal }];
    expect(ruleId).toBe("rule-allocation");
    expect(options.request).toBeInstanceOf(Request);
    expect(options.rateLimitKey).toBe("vm-allocation:team-1");
    expect(options.signal).toBeInstanceOf(AbortSignal);
    expect(response?.status).toBe(429);
    expect(response?.headers.get("retry-after")).toBe("60");
    expect(await response?.json()).toMatchObject({
      error: "vm_allocation_rate_limited",
      retryAfterSeconds: 60,
    });
  });

  test("charges every provider allocation in a multi-attempt request", async () => {
    let checks = 0;
    const response = await enforceVmAllocationRateLimit({
      request: request(),
      route: "run.create",
      billingTeamId: "team-1",
      ruleId: "rule-allocation",
      isVercel: true,
      cost: 3,
      check: async () => ({ rateLimited: ++checks === 3 }),
    });

    expect(checks).toBe(3);
    expect(response?.status).toBe(429);
  });

  test("aborts a stalled Firewall check and fails closed", async () => {
    let observedSignal: AbortSignal | undefined;
    const response = await enforceVmAllocationRateLimit({
      request: request(),
      route: "vm.create",
      billingTeamId: "team-1",
      ruleId: "rule-allocation",
      isVercel: true,
      timeoutMs: 10,
      check: async (_ruleId, options) => {
        observedSignal = options.signal;
        if (!options.signal) return { rateLimited: false };
        return await new Promise((_, reject) => {
          options.signal.addEventListener("abort", () => reject(options.signal.reason), { once: true });
        });
      },
    });

    expect(observedSignal?.aborted).toBe(true);
    expect(response?.status).toBe(503);
    expect(await response?.json()).toMatchObject({ error: "rate_limit_unavailable" });
  });
});
