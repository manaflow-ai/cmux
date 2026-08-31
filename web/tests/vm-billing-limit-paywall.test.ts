import { describe, expect, test } from "bun:test";
import {
  defaultMemoryMbForPlan,
  isVmFreeAccessExpired,
  maxActiveVmsForPlan,
  maxMemoryMbForPlan,
  vmFreeAccessWindowDays,
} from "../services/vms/entitlements";
import { vmActiveLimitExceededResponse, vmFreeAccessExpiredResponse } from "../services/vms/routeHelpers";

async function body(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

describe("free plan VM allowance", () => {
  test("free users get no Cloud VMs by default — machines are a paid feature", () => {
    expect(maxActiveVmsForPlan("free", {})).toBe(0);
  });

  test("pro gets five machines by default", () => {
    expect(maxActiveVmsForPlan("pro", {})).toBe(5);
  });

  test("the free allowance stays env-overridable, including back to a demo allowance", () => {
    expect(maxActiveVmsForPlan("free", { CMUX_VM_FREE_MAX_ACTIVE_VMS: "7" })).toBe(7);
    expect(maxActiveVmsForPlan("free", { CMUX_VM_FREE_MAX_ACTIVE_VMS: "0" })).toBe(0);
  });
});

describe("Cloud VM memory allowance", () => {
  test("free defaults to 24 GB and caps at 24 GB", () => {
    expect(defaultMemoryMbForPlan("free", {})).toBe(24576);
    expect(maxMemoryMbForPlan("free", {})).toBe(24576);
  });

  test("paid plans default to 24 GB and cap at 32 GB", () => {
    expect(defaultMemoryMbForPlan("pro", {})).toBe(24576);
    expect(maxMemoryMbForPlan("pro", {})).toBe(32768);
  });

  test("memory defaults and caps are independently env-overridable", () => {
    const env = {
      CMUX_VM_PLAN_PRO_DEFAULT_MEMORY_MB: "16384",
      CMUX_VM_PLAN_PRO_MAX_MEMORY_MB: "24576",
    };
    expect(defaultMemoryMbForPlan("pro", env)).toBe(16384);
    expect(maxMemoryMbForPlan("pro", env)).toBe(24576);
  });
});

describe("active-limit response as the paywall moment", () => {
  test("a zero-allowance free plan is told Cloud VMs require a cmux Pro subscription", async () => {
    const response = vmActiveLimitExceededResponse({
      limit: 0,
      planId: "free",
      retryAction: "delete one first",
    });
    expect(response.status).toBe(402);
    const payload = await body(response);
    expect(payload.error).toBe("vm_active_limit_exceeded");
    expect(payload.message).toBe("Cloud VMs require a cmux Pro subscription.");
    expect(String(payload.action)).toContain("Subscribe to cmux Pro");
    expect(String(payload.action)).toContain("up to 5 active machines");
    expect(String(payload.action)).not.toContain("cmux vm rm");
    expect(payload.upgradeRequired).toBe(true);
    expect(payload.upgradeUrl).toBe("https://cmux.com/pricing");
  });

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

describe("free access window", () => {
  const days = (n: number) => n * 24 * 60 * 60 * 1000;
  const now = 1_800_000_000_000;

  test("defaults to 7 days and stays env-overridable", () => {
    expect(vmFreeAccessWindowDays({})).toBe(7);
    expect(vmFreeAccessWindowDays({ CMUX_VM_FREE_ACCESS_WINDOW_DAYS: "14" })).toBe(14);
  });

  test("a free machine expires after the window and not before", () => {
    expect(isVmFreeAccessExpired("free", now - days(8), {}, now)).toBe(true);
    expect(isVmFreeAccessExpired("free", new Date(now - days(8)), {}, now)).toBe(true);
    expect(isVmFreeAccessExpired("free", now - days(6), {}, now)).toBe(false);
  });

  test("a paid plan never expires, even for machines created on free", () => {
    expect(isVmFreeAccessExpired("pro", now - days(400), {}, now)).toBe(false);
    expect(isVmFreeAccessExpired("team", now - days(400), {}, now)).toBe(false);
  });

  test("window 0 disables the gate; unknown createdAt fails open", () => {
    expect(isVmFreeAccessExpired("free", now - days(400), { CMUX_VM_FREE_ACCESS_WINDOW_DAYS: "0" }, now)).toBe(false);
    expect(isVmFreeAccessExpired("free", null, {}, now)).toBe(false);
  });

  test("the expired response is the upgrade prompt, with delete as the out", async () => {
    const response = vmFreeAccessExpiredResponse({ vmId: "noble-wren", windowDays: 5 });
    expect(response.status).toBe(402);
    const payload = await body(response);
    expect(payload.error).toBe("vm_access_requires_pro");
    expect(payload.message).toContain("5 days");
    expect(payload.message).toContain("preserved");
    expect(String(payload.action)).toContain("https://cmux.com/pricing");
    expect(String(payload.action)).toContain("cmux vm rm noble-wren");
    expect(payload.upgradeRequired).toBe(true);
    expect(payload.upgradeUrl).toBe("https://cmux.com/pricing");
  });
});
