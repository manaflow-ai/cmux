import { PRO_PLAN_ID, TEAM_PLAN_ID } from "../billing/pro";

export type TeamEntitlementConfig = { readonly inviteeLimit: number | null; readonly upgradePlanId: string };
export const TEAM_ENTITLEMENTS: Readonly<Record<string, TeamEntitlementConfig>> = {
  [PRO_PLAN_ID]: { inviteeLimit: 3, upgradePlanId: TEAM_PLAN_ID },
  [TEAM_PLAN_ID]: { inviteeLimit: null, upgradePlanId: TEAM_PLAN_ID },
};
export class TeamUpgradeRequiredError extends Error {
  readonly code = "upgrade_required" as const; readonly status = 402 as const;
  constructor(readonly upgradePlanId = TEAM_PLAN_ID) { super("Upgrade required to add more team members."); this.name = "TeamUpgradeRequiredError"; }
}
export function ownerPlanIdFromMetadata(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = (metadata as { cmuxPlan?: unknown; cmuxVmPlan?: unknown }).cmuxPlan ?? (metadata as { cmuxVmPlan?: unknown }).cmuxVmPlan;
  return typeof value === "string" && value.trim() ? value.trim().toLowerCase() : null;
}
export function assertTeamEntitlement(input: { ownerPlanId: string | null | undefined; memberCount: number; pendingInviteCount: number; additionalInviteCount?: number; config?: Readonly<Record<string, TeamEntitlementConfig>> }): void {
  const rule = (input.config ?? TEAM_ENTITLEMENTS)[input.ownerPlanId?.trim().toLowerCase() ?? ""];
  if (!rule || rule.inviteeLimit === null) return;
  const invitees = Math.max(0, input.memberCount - 1) + input.pendingInviteCount + (input.additionalInviteCount ?? 0);
  if (invitees > rule.inviteeLimit) throw new TeamUpgradeRequiredError(rule.upgradePlanId);
}
export function memberAllowedAtUse(input: { ownerPlanId: string | null | undefined; memberIndex: number; config?: Readonly<Record<string, TeamEntitlementConfig>> }): boolean {
  const rule = (input.config ?? TEAM_ENTITLEMENTS)[input.ownerPlanId?.trim().toLowerCase() ?? ""];
  return !rule || rule.inviteeLimit === null || input.memberIndex <= rule.inviteeLimit;
}
