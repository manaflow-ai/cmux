/**
 * The ordered cmux plan tiers. Each tier includes every feature of the tiers
 * below it, so gate on the ordering (`planIncludes(planId, "pro")`) rather
 * than on a plan string: Max, and any later higher tier, then keeps
 * everything Pro has.
 *
 * Team and Founder's Edition grant the Pro feature set. Their own machine
 * allowance (Team seats) is applied by the VM entitlements, not here.
 */
export type PlanTier = "free" | "go" | "pro" | "max";

const PLAN_TIER_RANK: Readonly<Record<PlanTier, number>> = { free: 0, go: 1, pro: 2, max: 3 };

const PLAN_TIER_BY_ID: Readonly<Record<string, PlanTier>> = {
  free: "free",
  go: "go",
  pro: "pro",
  team: "pro",
  founders: "pro",
  max: "max",
};

/** The tier a plan ID grants, or null for an unknown ID. */
export function planTier(planId: string | null | undefined): PlanTier | null {
  if (typeof planId !== "string") return null;
  const key = planId.trim().toLowerCase();
  return Object.hasOwn(PLAN_TIER_BY_ID, key) ? PLAN_TIER_BY_ID[key]! : null;
}

/** Sort key for a tier or plan ID; an unknown ID ranks with Free. */
export function planTierRank(planId: string | null | undefined): number {
  return PLAN_TIER_RANK[planTier(planId) ?? "free"];
}

/** Whether a plan includes every feature of `required`. Unknown IDs include nothing. */
export function planIncludes(planId: string | null | undefined, required: PlanTier): boolean {
  const tier = planTier(planId);
  return tier !== null && PLAN_TIER_RANK[tier] >= PLAN_TIER_RANK[required];
}

/** The plan an upgrade from `planId` offers, or null at the top tier. */
export function nextUpgradePlanId(planId: string | null | undefined): "pro" | "max" | null {
  if (planIncludes(planId, "max")) return null;
  return planIncludes(planId, "pro") ? "max" : "pro";
}
