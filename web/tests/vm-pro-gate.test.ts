import { describe, expect, test } from "bun:test";

import {
  isPaidVmPlan,
  isVmFreeProvisioningAllowed,
  isVmProGateBlocked,
  isVmProGateEnforced,
} from "../services/vms/entitlements";

const ent = (planId: string) => ({ planId });

describe("Cloud VM Pro gate", () => {
  test("isPaidVmPlan recognizes pro, team, and founders, not free", () => {
    expect(isPaidVmPlan("pro")).toBe(true);
    expect(isPaidVmPlan("team")).toBe(true);
    expect(isPaidVmPlan("PRO")).toBe(true);
    // Founder's Edition: one-time purchase granted via cmuxVmPlan, no
    // subscription behind it — paid for the expiry window and the pro gate.
    expect(isPaidVmPlan("founders")).toBe(true);
    expect(isPaidVmPlan("Founders")).toBe(true);
    expect(isPaidVmPlan("free")).toBe(false);
    expect(isPaidVmPlan("")).toBe(false);
    expect(isPaidVmPlan("enterprise-unknown")).toBe(false);
  });

  test("enforcement is on by default and only an explicit allow switch opens it", () => {
    expect(isVmProGateEnforced({})).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "1" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "0" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "false" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "1" })).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "ON" })).toBe(false);
  });

  test("legacy CMUX_VM_REQUIRE_PRO false values remain a compatibility escape hatch", () => {
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "0" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "false" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "off" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "garbage" })).toBe(false);
    // The new switch is authoritative when both names are present.
    expect(isVmFreeProvisioningAllowed({
      CMUX_VM_ALLOW_FREE_PROVISIONING: "0",
      CMUX_VM_REQUIRE_PRO: "0",
    })).toBe(false);
  });

  test("the explicit free-provisioning switch never blocks any plan", () => {
    const env = { CMUX_VM_ALLOW_FREE_PROVISIONING: "1" };
    expect(isVmProGateBlocked(ent("free"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("pro"), {})).toBe(false);
  });

  test("default enforcement blocks every non-paid plan but allows pro/team/founders", () => {
    const env = {};
    expect(isVmProGateBlocked(ent("free"), env)).toBe(true);
    expect(isVmProGateBlocked(ent(""), env)).toBe(true);
    expect(isVmProGateBlocked(ent("unknown"), env)).toBe(true);
    expect(isVmProGateBlocked(ent("pro"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("team"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("founders"), env)).toBe(false);
  });
});
