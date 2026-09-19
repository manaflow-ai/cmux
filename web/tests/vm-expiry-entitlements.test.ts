import { describe, expect, test } from "bun:test";
import { resolveExpiredVmEntitlements, type ExpiryEntitlementLookup } from "../services/vms/expiryEntitlements";

const environment = { NODE_ENV: "production" };
const personal = { userId: "user", billingTeamId: "user" };
const lookup = (userMetadata: unknown, teamMetadata: unknown = {}): ExpiryEntitlementLookup => ({
  getUser: async () => ({ clientReadOnlyMetadata: userMetadata }),
  getTeam: async () => ({ clientReadOnlyMetadata: teamMetadata }),
});

describe("expiry current entitlement lookup", () => {
  test("resolves a personal free payer without looking up a team named after the user", async () => {
    expect(await resolveExpiredVmEntitlements(personal, {
      ...lookup({}), getTeam: async () => { throw new Error("not a team"); },
    }, environment)).toEqual({ planId: "free" });
  });

  for (const plan of ["go", "pro", "max", "team", "founders"]) {
    for (const key of ["cmuxPlan", "cmuxVmPlan"]) {
      test(`protects personal ${key} ${plan}`, async () => {
        expect(await resolveExpiredVmEntitlements(personal, lookup({ [key]: plan }), environment)).toEqual({ planId: plan });
      });
      test(`protects team ${key} ${plan}`, async () => {
        expect(await resolveExpiredVmEntitlements({ ...personal, billingTeamId: "team" }, lookup({}, { [key]: plan }), environment)).toEqual({ planId: plan });
      });
    }
  }

  test("uses the shared metadata precedence so a lower grant cannot hide Max", async () => {
    expect(await resolveExpiredVmEntitlements(personal, lookup({ cmuxVmPlan: "pro", cmuxPlan: "max" }), environment)).toEqual({ planId: "max" });
  });

  test("protects paid defaults using the same entitlement policy as requests", async () => {
    expect((await resolveExpiredVmEntitlements(personal, lookup({}), {
      ...environment, CMUX_VM_ALLOW_FREE_PROVISIONING: "1", CMUX_VM_DEFAULT_PLAN: "pro",
    }))?.planId).toBe("pro");
  });

  test("missing users, missing teams, unknown plans and failed reads stay unknown", async () => {
    expect(await resolveExpiredVmEntitlements(personal, { ...lookup({}), getUser: async () => null }, environment)).toBeNull();
    expect(await resolveExpiredVmEntitlements({ ...personal, billingTeamId: "team" }, { ...lookup({}), getTeam: async () => null }, environment)).toBeNull();
    expect(await resolveExpiredVmEntitlements(personal, lookup({ cmuxVmPlan: "custom" }), environment)).toBeNull();
    expect(await resolveExpiredVmEntitlements(personal, { ...lookup({}), getUser: async () => { throw new Error("unavailable"); } }, environment)).toBeNull();
  });
});
