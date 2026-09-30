import { describe, expect, test } from "bun:test";
import { assertTeamEntitlement, memberAllowedAtUse, resolveTeamOwnerPlan, TeamUpgradeRequiredError } from "../services/teams/entitlementPolicy";

describe("team entitlement policy", () => {
  test("uses owner's Pro plan and counts pending invites", () => {
    expect(resolveTeamOwnerPlan({ ownerPlanId: "pro", inviterPlanId: "team" })).toBe("pro");
    expect(() => assertTeamEntitlement({ ownerPlanId: "pro", memberCount: 1, pendingInviteCount: 3, additionalInviteCount: 1 })).toThrow(TeamUpgradeRequiredError);
    expect(() => assertTeamEntitlement({ ownerPlanId: "free", memberCount: 1, pendingInviteCount: 99, additionalInviteCount: 1 })).not.toThrow();
  });
  test("Team is uncapped and config changes move the limit", () => {
    expect(() => assertTeamEntitlement({ ownerPlanId: "team", memberCount: 1, pendingInviteCount: 100, additionalInviteCount: 100 })).not.toThrow();
    expect(() => assertTeamEntitlement({ ownerPlanId: "pro", memberCount: 1, pendingInviteCount: 2, additionalInviteCount: 1, config: { pro: { inviteeLimit: 2, upgradePlanId: "team" } } })).toThrow();
  });
  test("existing members remain usable after downgrade; later members are blocked", () => {
    expect(memberAllowedAtUse({ ownerPlanId: "free", memberIndex: 99 })).toBe(true);
    expect(memberAllowedAtUse({ ownerPlanId: "pro", memberIndex: 3 })).toBe(true);
    expect(memberAllowedAtUse({ ownerPlanId: "pro", memberIndex: 4 })).toBe(false);
  });
});
