import { describe, expect, test } from "bun:test";
import { maxActiveVmsForPlan } from "../services/vms/entitlements";
import { vmActiveLimitExceededResponse } from "../services/vms/routeHelpers";

async function body(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

describe("free plan VM allowance", () => {
  test("free users get 3 Cloud VMs by default", () => {
    expect(maxActiveVmsForPlan("free", {})).toBe(2);
  });

  test("paid plans keep a higher default allowance", () => {
    expect(maxActiveVmsForPlan("pro", {})).toBe(15);
  });

  test("the free allowance stays env-overridable", () => {
    expect(maxActiveVmsForPlan("free", { CMUX_VM_FREE_MAX_ACTIVE_VMS: "7" })).toBe(7);
  });
});

describe("active-limit response as the paywall moment", () => {
  test("a free plan over the limit is prompted to upgrade to Pro", async () => {
    const response = vmActiveLimitExceededResponse({
      limit: 3,
      planId: "free",
      retryAction: "delete one first",
    });
    expect(response.status).toBe(402);
    const payload = await body(response);
    expect(payload.error).toBe("vm_active_limit_exceeded");
    expect(payload.message).toContain("free plan includes 3 Cloud VMs");
    expect(String(payload.action)).toContain("Upgrade to cmux Pro");
    expect(String(payload.action)).toContain("https://cmux.com/pricing");
    expect(payload.upgradeRequired).toBe(true);
    expect(payload.upgradeUrl).toBe("https://cmux.com/pricing");
  });

  test("a paid plan over the limit gets operational guidance, not a paywall", async () => {
    const response = vmActiveLimitExceededResponse({
      limit: 10,
      planId: "pro",
      retryAction: "Run `cmux vm ls`, then stop or delete an active VM.",
    });
    expect(response.status).toBe(402);
    const payload = await body(response);
    expect(payload.error).toBe("vm_active_limit_exceeded");
    expect(payload.message).toContain("10 active Cloud VMs");
    expect(String(payload.action)).toContain("cmux vm ls");
    expect(payload.upgradeRequired).toBeUndefined();
  });

  test("the singular limit reads naturally", async () => {
    const response = vmActiveLimitExceededResponse({
      limit: 1,
      planId: "free",
      retryAction: "unused",
    });
    const payload = await body(response);
    expect(payload.message).toContain("1 Cloud VM.");
  });
});
