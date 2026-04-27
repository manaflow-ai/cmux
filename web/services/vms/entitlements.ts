import type { AuthedUser } from "./auth";

export type VmEntitlements = {
  readonly planId: string;
  readonly billingTeamId: string;
  readonly maxActiveVms: number;
};

export function resolveVmEntitlements(
  user: AuthedUser,
  env: Record<string, string | undefined> = process.env,
): VmEntitlements {
  const planId = normalizedPlanId(user.billingPlanId ?? env.CMUX_VM_DEFAULT_PLAN ?? "free");
  return {
    planId,
    billingTeamId: user.billingTeamId,
    maxActiveVms: activeVmLimitForPlan(planId, env),
  };
}

function activeVmLimitForPlan(planId: string, env: Record<string, string | undefined>): number {
  const planKey = planId.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`];
  if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`);

  if (planId === "free") {
    return positiveInteger(env.CMUX_VM_FREE_MAX_ACTIVE_VMS ?? "1", "CMUX_VM_FREE_MAX_ACTIVE_VMS");
  }

  return positiveInteger(env.CMUX_VM_PAID_MAX_ACTIVE_VMS ?? "10", "CMUX_VM_PAID_MAX_ACTIVE_VMS");
}

function normalizedPlanId(planId: string): string {
  const normalized = planId.trim().toLowerCase();
  return normalized || "free";
}

function positiveInteger(raw: string, key: string): number {
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${key} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${key} must be a positive integer`);
  return parsed;
}
