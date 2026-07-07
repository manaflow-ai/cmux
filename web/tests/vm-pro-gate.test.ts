import { describe, expect, test } from "bun:test";

import {
  isPaidVmPlan,
  isVmProGateBlocked,
  isVmProGateEnforced,
  resolveVmProGateDecision,
  resolveVmTrialState,
  vmTrialDurationMs,
} from "../services/vms/entitlements";

const ent = (planId: string, vmTrialStartedAt: string | null = null) => ({ planId, vmTrialStartedAt });
const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_800_000_000_000; // fixed instant for deterministic trial math
const iso = (ms: number) => new Date(ms).toISOString();
const enforce = { CMUX_VM_REQUIRE_PRO: "1" };

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
});

describe("Cloud VM trial state", () => {
  test("default trial is 7 days, overridable via CMUX_VM_TRIAL_DAYS", () => {
    expect(vmTrialDurationMs({})).toBe(7 * DAY);
    expect(vmTrialDurationMs({ CMUX_VM_TRIAL_DAYS: "3" })).toBe(3 * DAY);
    expect(vmTrialDurationMs({ CMUX_VM_TRIAL_DAYS: "0" })).toBe(7 * DAY); // invalid falls back
    expect(vmTrialDurationMs({ CMUX_VM_TRIAL_DAYS: "junk" })).toBe(7 * DAY);
  });

  test("never started when no timestamp", () => {
    const s = resolveVmTrialState(null, {}, NOW);
    expect(s).toEqual({ started: false, active: false, expired: false, daysRemaining: 0, endsAt: null });
  });

  test("active within the window, with whole days remaining", () => {
    const s = resolveVmTrialState(iso(NOW - 2 * DAY), {}, NOW);
    expect(s.started).toBe(true);
    expect(s.active).toBe(true);
    expect(s.expired).toBe(false);
    expect(s.daysRemaining).toBe(5);
  });

  test("expired once the window elapses", () => {
    const s = resolveVmTrialState(iso(NOW - 8 * DAY), {}, NOW);
    expect(s.active).toBe(false);
    expect(s.expired).toBe(true);
    expect(s.daysRemaining).toBe(0);
  });

  test("malformed timestamp is treated as never started", () => {
    expect(resolveVmTrialState("not-a-date", {}, NOW).started).toBe(false);
  });
});

describe("Cloud VM gate decision", () => {
  test("gate off → always allowed regardless of plan/trial", () => {
    expect(resolveVmProGateDecision(ent("free"), {}, NOW)).toBe("allowed");
    expect(resolveVmProGateDecision(ent("pro"), {}, NOW)).toBe("allowed");
  });

  test("paid plans are allowed even under enforcement", () => {
    expect(resolveVmProGateDecision(ent("pro"), enforce, NOW)).toBe("allowed");
    expect(resolveVmProGateDecision(ent("team"), enforce, NOW)).toBe("allowed");
  });

  test("free with no trial → trial_available (route auto-starts the trial)", () => {
    expect(resolveVmProGateDecision(ent("free"), enforce, NOW)).toBe("trial_available");
  });

  test("free with an active trial → allowed", () => {
    expect(resolveVmProGateDecision(ent("free", iso(NOW - 2 * DAY)), enforce, NOW)).toBe("allowed");
  });

  test("free with an elapsed trial → trial_expired (upgrade wall)", () => {
    expect(resolveVmProGateDecision(ent("free", iso(NOW - 8 * DAY)), enforce, NOW)).toBe("trial_expired");
  });

  test("isVmProGateBlocked is true only for an expired trial", () => {
    expect(isVmProGateBlocked(ent("free"), enforce, NOW)).toBe(false); // trial available, not blocked
    expect(isVmProGateBlocked(ent("free", iso(NOW - 2 * DAY)), enforce, NOW)).toBe(false); // active
    expect(isVmProGateBlocked(ent("free", iso(NOW - 8 * DAY)), enforce, NOW)).toBe(true); // expired
    expect(isVmProGateBlocked(ent("pro"), enforce, NOW)).toBe(false);
    expect(isVmProGateBlocked(ent("free"), {}, NOW)).toBe(false); // gate off
  });
});
