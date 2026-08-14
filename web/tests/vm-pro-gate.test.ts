import { describe, expect, test } from "bun:test";

import {
  isPaidVmPlan,
  isVmProGateBlocked,
  isVmProGateEnforced,
} from "../services/vms/entitlements";

const ent = (planId: string) => ({ planId });

describe("Cloud VM Pro gate", () => {
  test("isPaidVmPlan recognizes pro and team, not free", () => {
    expect(isPaidVmPlan("pro")).toBe(true);
    expect(isPaidVmPlan("team")).toBe(true);
    expect(isPaidVmPlan("PRO")).toBe(true);
    expect(isPaidVmPlan("free")).toBe(false);
    expect(isPaidVmPlan("")).toBe(false);
    expect(isPaidVmPlan("enterprise-unknown")).toBe(false);
  });

  test("enforcement is off unless CMUX_VM_REQUIRE_PRO is truthy (ships dark)", () => {
    expect(isVmProGateEnforced({})).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "" })).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "0" })).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "false" })).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "1" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "true" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "ON" })).toBe(true);
  });

  test("enforcement OFF never blocks any plan", () => {
    expect(isVmProGateBlocked(ent("free"), {})).toBe(false);
    expect(isVmProGateBlocked(ent("pro"), {})).toBe(false);
  });

  test("enforcement ON blocks free but allows pro/team", () => {
    const env = { CMUX_VM_REQUIRE_PRO: "1" };
    expect(isVmProGateBlocked(ent("free"), env)).toBe(true);
    expect(isVmProGateBlocked(ent("pro"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("team"), env)).toBe(false);
  });
});
