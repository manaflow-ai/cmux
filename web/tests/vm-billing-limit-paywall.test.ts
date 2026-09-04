import { describe, expect, test } from "bun:test";
import {
  PLAN_MACHINE_MEMORY_MB,
  VM_MEMORY_OPTIONS_MB,
  defaultMemoryMbForPlan,
  isVmFreeAccessExpired,
  maxActiveVmsForPlan,
  maxMemoryMbForPlan,
  memoryOptionsMbForPlan,
  vcpusForMemoryMb,
  vmDiskMb,
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

  test("paid plans get the advertised 50-machine allowance", () => {
    expect(maxActiveVmsForPlan("pro", {})).toBe(50);
    expect(maxActiveVmsForPlan("team", {})).toBe(50);
    expect(maxActiveVmsForPlan("founders", {})).toBe(50);
  });

  test("a Team subscription gets 50 machines per paid seat", () => {
    expect(maxActiveVmsForPlan("team", {}, { seats: 4 })).toBe(200);
    expect(maxActiveVmsForPlan("team", {}, { seats: 1 })).toBe(50);
    expect(maxActiveVmsForPlan("team", {}, { seats: null })).toBe(50);
    expect(maxActiveVmsForPlan("team", {}, { seats: 0 })).toBe(50);
    // Seats only mean something on the Team plan.
    expect(maxActiveVmsForPlan("pro", {}, { seats: 4 })).toBe(50);
    expect(maxActiveVmsForPlan("free", {}, { seats: 4 })).toBe(0);
    // Operator brakes are absolute for the whole team, never multiplied.
    expect(maxActiveVmsForPlan("team", { CMUX_VM_PLAN_TEAM_MAX_ACTIVE_VMS: "2" }, { seats: 3 })).toBe(2);
    expect(maxActiveVmsForPlan("team", { CMUX_VM_PAID_MAX_ACTIVE_VMS: "5" }, { seats: 4 })).toBe(5);
  });

  test("operator brakes: a plan-specific cap wins over the paid-wide cap", () => {
    expect(maxActiveVmsForPlan("pro", { CMUX_VM_PAID_MAX_ACTIVE_VMS: "5" })).toBe(5);
    expect(maxActiveVmsForPlan("pro", {
      CMUX_VM_PAID_MAX_ACTIVE_VMS: "5",
      CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS: "25",
    })).toBe(25);
    expect(maxActiveVmsForPlan("team", { CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS: "25" })).toBe(50);
    expect(() => maxActiveVmsForPlan("pro", { CMUX_VM_PAID_MAX_ACTIVE_VMS: "0" })).toThrow();
  });

  test("free allowance is env-overridable only with the explicit escape hatch", () => {
    expect(maxActiveVmsForPlan("free", { CMUX_VM_FREE_MAX_ACTIVE_VMS: "7" })).toBe(0);
    expect(maxActiveVmsForPlan("free", {
      CMUX_VM_ALLOW_FREE_PROVISIONING: "1",
      CMUX_VM_FREE_MAX_ACTIVE_VMS: "7",
    })).toBe(7);
    expect(maxActiveVmsForPlan("free", {
      CMUX_VM_ALLOW_FREE_PROVISIONING: "1",
      CMUX_VM_FREE_MAX_ACTIVE_VMS: "0",
    })).toBe(0);
  });

  test("a plan-specific free override cannot bypass the default gate", () => {
    expect(maxActiveVmsForPlan("free", {
      CMUX_VM_PLAN_FREE_MAX_ACTIVE_VMS: "9",
    })).toBe(0);
    expect(maxActiveVmsForPlan("unknown", {
      CMUX_VM_PLAN_UNKNOWN_MAX_ACTIVE_VMS: "9",
    })).toBe(0);
  });
});

describe("Cloud VM memory allowance", () => {
  test("every plan defaults to and caps at the 20 GB plan machine", () => {
    expect(PLAN_MACHINE_MEMORY_MB).toBe(20480);
    expect(defaultMemoryMbForPlan("free", {})).toBe(20480);
    expect(maxMemoryMbForPlan("free", {})).toBe(20480);
    expect(defaultMemoryMbForPlan("pro", {})).toBe(20480);
    expect(maxMemoryMbForPlan("pro", {})).toBe(20480);
    expect(VM_MEMORY_OPTIONS_MB).toEqual([20480]);
  });

  test("vCPUs follow memory at one per 4 GB, so the plan machine is 5 vCPU", () => {
    expect(vcpusForMemoryMb(20480)).toBe(5);
    expect(vcpusForMemoryMb(16384)).toBe(4);
    expect(vcpusForMemoryMb(2048)).toBe(1);
    expect(vcpusForMemoryMb(5000)).toBe(2);
  });

  test("every machine is grown to a 200 GB disk unless an operator overrides it", () => {
    expect(vmDiskMb({})).toBe(204800);
    expect(vmDiskMb({ CMUX_VM_DISK_MB: "65536" })).toBe(65536);
    expect(() => vmDiskMb({ CMUX_VM_DISK_MB: "0" })).toThrow();
  });

  test("accepted sizes follow the plan ceiling and always include the configured default", () => {
    expect(memoryOptionsMbForPlan("pro", {})).toEqual([20480]);
    // An operator default below the catalog stays creatable, so an omitted
    // size never 400s after an override.
    expect(memoryOptionsMbForPlan("free", { CMUX_VM_FREE_DEFAULT_MEMORY_MB: "8192" })).toEqual([8192, 20480]);
    // A lower ceiling trims the catalog and keeps the (clamped) default.
    expect(memoryOptionsMbForPlan("pro", { CMUX_VM_PLAN_PRO_MAX_MEMORY_MB: "16384" })).toEqual([16384]);
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
    expect(String(payload.action)).not.toContain("up to");
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
