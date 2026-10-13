import { describe, expect, test } from "bun:test";

import type { AuthedTeam, AuthedUser } from "../services/vms/auth";
import {
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../services/vms/entitlements";
import { resolveVmProvisioningAccountScope } from "../services/vms/routeHelpers";
import {
  TEAM_PLAN_REQUIRED_METADATA_KEY,
  teamPlanRequiredFromMetadata,
} from "../services/billing/teamResolution";

// A team someone creates after sign-up must not borrow their personal plan:
// otherwise every new team is another 5 machines and another resource pool.
// The team Stack creates at sign-up keeps the personal plan.

const ENV = {};
const SIGNUP_TEAM = "signup-team";

function team(id: string, input: Partial<AuthedTeam> = {}): AuthedTeam {
  return { id, displayName: id, billingPlanId: null, billingSeats: null, ...input };
}

/** A caller with a personal plan, their sign-up team, and `extra` created teams. */
function caller(input: {
  readonly personalPlan: string | null;
  readonly extra?: readonly AuthedTeam[];
  readonly selected?: string;
}): AuthedUser {
  const teams = [team(SIGNUP_TEAM), ...(input.extra ?? [])];
  const selected = teams.find((candidate) => candidate.id === (input.selected ?? SIGNUP_TEAM))!;
  return {
    id: "user-1",
    displayName: "User",
    primaryEmail: "user@example.com",
    billingCustomerType: "team",
    billingTeamId: selected.id,
    selectedTeamId: selected.id,
    teams,
    teamIds: teams.map((candidate) => candidate.id),
    userBillingPlanId: input.personalPlan,
    // What auth computes: the team's own plan, else the personal plan unless
    // the team is a created one.
    billingPlanId: selected.billingPlanId ?? (selected.teamPlanRequired ? null : input.personalPlan),
    billingSeats: selected.billingSeats,
  };
}

const created = (id: string, input: Partial<AuthedTeam> = {}) => team(id, { teamPlanRequired: true, ...input });

function provisioningRequest(teamId?: string): Request {
  return new Request("https://cmux.test/api/vm", {
    method: "POST",
    headers: teamId ? { "x-cmux-team-id": teamId } : {},
  });
}

describe("created teams need their own Team plan", () => {
  test("the sign-up team keeps the personal Pro allowance", () => {
    const entitlements = resolveVmEntitlements(caller({ personalPlan: "pro" }), ENV);
    expect(entitlements.planId).toBe("pro");
    expect(entitlements.maxActiveVms).toBe(5);
    expect(entitlements.resourcePool).not.toBeNull();
    expect(entitlements.teamPlanRequired).toBeUndefined();
  });

  test("a Pro user's new unpaid team gets no machines and no pool", () => {
    const user = caller({ personalPlan: "pro", extra: [created("new-team")], selected: "new-team" });
    const entitlements = resolveVmEntitlements(user, ENV);
    expect(entitlements.billingTeamId).toBe("new-team");
    expect(entitlements.planId).toBe("free");
    expect(entitlements.maxActiveVms).toBe(0);
    expect(entitlements.resourcePool).toBeNull();
    expect(entitlements.teamPlanRequired).toBe(true);
    expect(isVmProGateBlocked(entitlements, ENV)).toBe(true);
  });

  test("several new unpaid teams add nothing, selected or requested", () => {
    const extra = [created("team-a"), created("team-b"), created("team-c")];
    const user = caller({ personalPlan: "pro", extra });
    let total = resolveVmEntitlements(user, ENV).maxActiveVms ?? 0;
    for (const candidate of extra) {
      const requested = resolveVmEntitlements(user, ENV, { requestedBillingTeamId: candidate.id });
      expect(requested.maxActiveVms).toBe(0);
      expect(requested.resourcePool).toBeNull();
      total += requested.maxActiveVms ?? 0;
      const selected = resolveVmEntitlements(caller({ personalPlan: "pro", extra, selected: candidate.id }), ENV);
      expect(selected.maxActiveVms).toBe(0);
    }
    expect(total).toBe(5);
  });

  test("Max does not follow its owner into a new unpaid team", () => {
    const user = caller({ personalPlan: "max", extra: [created("new-team")], selected: "new-team" });
    const entitlements = resolveVmEntitlements(user, ENV);
    expect(entitlements.planId).toBe("free");
    expect(entitlements.maxActiveVms).toBe(0);
    expect(entitlements.resourcePool).toBeNull();
  });

  test("a created team with the Team plan gets its seat-scaled allowance", () => {
    const paid = created("paid-team", { billingPlanId: "team", billingSeats: 3 });
    const freeMember = caller({ personalPlan: null, extra: [paid], selected: "paid-team" });
    const entitlements = resolveVmEntitlements(freeMember, ENV);
    expect(entitlements.planId).toBe("team");
    expect(entitlements.maxActiveVms).toBe(15);
    expect(entitlements.resourcePool).toEqual({ vcpus: 60, memoryMb: 3 * 40 * 1024 });
    expect(entitlements.teamPlanRequired).toBeUndefined();
    const requested = resolveVmEntitlements(caller({ personalPlan: "pro", extra: [paid] }), ENV, { requestedBillingTeamId: "paid-team" });
    expect(requested.maxActiveVms).toBe(15);
  });

  test("a free user stays on the Pro gate, not the Team plan gate", () => {
    const entitlements = resolveVmEntitlements(caller({ personalPlan: null }), ENV);
    expect(entitlements.maxActiveVms).toBe(0);
    expect(entitlements.teamPlanRequired).toBeUndefined();
    expect(isVmProGateBlocked(entitlements, ENV)).toBe(true);
  });

  test("provisioning in a new unpaid team answers vm_requires_team_plan", async () => {
    const user = caller({ personalPlan: "pro", extra: [created("new-team")] });
    const scope = await resolveVmProvisioningAccountScope(user, provisioningRequest("new-team"));
    expect(scope.ok).toBe(false);
    if (scope.ok) return;
    expect(scope.response.status).toBe(402);
    const body = await scope.response.json() as Record<string, unknown>;
    expect(body.error).toBe("vm_requires_team_plan");
    expect(body.upgradePlanId).toBe("team");
    expect(body.upgradeUrl).toBe("https://cmux.com/dashboard/billing?team=new-team");
    expect(String(body.message)).toContain("Team plan");

    const signup = await resolveVmProvisioningAccountScope(user, provisioningRequest(SIGNUP_TEAM));
    expect(signup.ok).toBe(true);
  });

  test("a free user's refusal is still vm_requires_pro", async () => {
    const scope = await resolveVmProvisioningAccountScope(caller({ personalPlan: null }), provisioningRequest());
    expect(scope.ok).toBe(false);
    if (scope.ok) return;
    expect((await scope.response.json() as { error: string }).error).toBe("vm_requires_pro");
  });

  test("the metadata flag reads only an explicit true", () => {
    expect(teamPlanRequiredFromMetadata({ [TEAM_PLAN_REQUIRED_METADATA_KEY]: true })).toBe(true);
    expect(teamPlanRequiredFromMetadata({ [TEAM_PLAN_REQUIRED_METADATA_KEY]: "true" })).toBe(false);
    expect(teamPlanRequiredFromMetadata({})).toBe(false);
    expect(teamPlanRequiredFromMetadata(null)).toBe(false);
  });
});
