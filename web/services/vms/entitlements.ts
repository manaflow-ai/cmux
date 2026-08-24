import type { AuthedUser } from "./auth";
import type { BillingCustomerType } from "./billingGateway";
import { PRO_PLAN_ID, TEAM_PLAN_ID } from "../billing/pro";

export type VmEntitlements = {
  readonly planId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly maxActiveVms: number;
};

export type VmEntitlementOptions = {
  readonly requestedBillingTeamId?: string | null;
  readonly requireTeam?: boolean;
};

export type VmBillingTeamErrorCode =
  | "vm_billing_team_required"
  | "vm_billing_team_not_found";

export class VmBillingTeamResolutionError extends Error {
  readonly code: VmBillingTeamErrorCode;
  readonly status: number;

  constructor(input: {
    readonly code: VmBillingTeamErrorCode;
    readonly status: number;
    readonly message: string;
  }) {
    super(input.message);
    this.name = "VmBillingTeamResolutionError";
    this.code = input.code;
    this.status = input.status;
  }
}

export function resolveVmEntitlements(
  user: AuthedUser,
  env: Record<string, string | undefined> = process.env,
  options: VmEntitlementOptions = {},
): VmEntitlements {
  const billing = resolveBillingContext(user, options);
  const planId = normalizedPlanId(billing.billingPlanId ?? env.CMUX_VM_DEFAULT_PLAN ?? "free");
  return {
    planId,
    billingCustomerType: billing.billingCustomerType,
    billingTeamId: billing.billingTeamId,
    maxActiveVms: maxActiveVmsForPlan(planId, env),
  };
}

export function isVmBillingTeamResolutionError(err: unknown): err is VmBillingTeamResolutionError {
  return err instanceof VmBillingTeamResolutionError;
}

function resolveBillingContext(
  user: AuthedUser,
  options: VmEntitlementOptions,
): {
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string | null;
} {
  const requestedTeamId = normalizedOptionalString(options.requestedBillingTeamId);
  if (requestedTeamId) {
    const team = user.teams.find((candidate) => candidate.id === requestedTeamId);
    if (!team) {
      throw new VmBillingTeamResolutionError({
        code: "vm_billing_team_not_found",
        status: 403,
        message: "The requested billing team is not available for this Stack Auth user.",
      });
    }
    return {
      billingCustomerType: "team",
      billingTeamId: team.id,
      billingPlanId: team.billingPlanId ?? user.userBillingPlanId,
    };
  }

  if (user.billingCustomerType === "team") {
    return {
      billingCustomerType: "team",
      billingTeamId: user.billingTeamId,
      billingPlanId: user.billingPlanId ?? user.userBillingPlanId,
    };
  }

  if (user.teams.length > 1) {
    throw new VmBillingTeamResolutionError({
      code: "vm_billing_team_required",
      status: 409,
      message: "This Stack Auth user has multiple teams. Send X-Cmux-Team-Id so Cloud VM billing is explicit.",
    });
  }

  if (options.requireTeam) {
    throw new VmBillingTeamResolutionError({
      code: "vm_billing_team_required",
      status: 409,
      message: "Stack Auth did not return a team. Enable personal team creation on sign-up before creating Cloud VMs.",
    });
  }

  return {
    billingCustomerType: "user",
    billingTeamId: user.billingTeamId,
    billingPlanId: user.userBillingPlanId,
  };
}

/**
 * Machine sizes a person can pick, as memory in MB. Blaxel scales vCPUs with
 * memory (a 4 GB machine reports 2 cpus), so memory is the whole size story.
 */
export const VM_MEMORY_OPTIONS_MB: readonly number[] = [2048, 4096, 8192, 16384, 32768];

/** Largest machine a plan may create. Env-overridable per plan. */
export function maxMemoryMbForPlan(
  planId: string | null | undefined,
  env: Record<string, string | undefined> = process.env,
): number {
  const normalized = normalizedPlanId(planId ?? "");
  const planKey = normalized.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_MEMORY_MB`];
  if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_MEMORY_MB`);
  if (normalized === "free") {
    return positiveInteger(env.CMUX_VM_FREE_MAX_MEMORY_MB ?? "4096", "CMUX_VM_FREE_MAX_MEMORY_MB");
  }
  return positiveInteger(env.CMUX_VM_PAID_MAX_MEMORY_MB ?? "32768", "CMUX_VM_PAID_MAX_MEMORY_MB");
}

/** Size a plan gets when it doesn't ask for one; never above the plan's max. */
export function defaultMemoryMbForPlan(
  planId: string | null | undefined,
  env: Record<string, string | undefined> = process.env,
): number {
  const normalized = normalizedPlanId(planId ?? "");
  const planKey = normalized.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  const specific = env[`CMUX_VM_PLAN_${planKey}_DEFAULT_MEMORY_MB`];
  const raw = specific?.trim()
    ? positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_DEFAULT_MEMORY_MB`)
    : normalized === "free"
      ? positiveInteger(env.CMUX_VM_FREE_DEFAULT_MEMORY_MB ?? "4096", "CMUX_VM_FREE_DEFAULT_MEMORY_MB")
      : positiveInteger(env.CMUX_VM_PAID_DEFAULT_MEMORY_MB ?? "8192", "CMUX_VM_PAID_DEFAULT_MEMORY_MB");
  return Math.min(raw, maxMemoryMbForPlan(planId, env));
}

export function maxActiveVmsForPlan(
  planId: string | null | undefined,
  env: Record<string, string | undefined> = process.env,
): number {
  return activeVmLimitForPlan(normalizedPlanId(planId ?? ""), env);
}

/** A paid Cloud VM plan is Pro or Team; everything else (free) is not. */
export function isPaidVmPlan(planId: string): boolean {
  const normalized = normalizedPlanId(planId);
  return normalized === PRO_PLAN_ID || normalized === TEAM_PLAN_ID;
}

/**
 * Whether Cloud VM provisioning is gated behind a paid plan. Ships dark: the
 * gate is OFF unless CMUX_VM_REQUIRE_PRO is explicitly truthy, so free users
 * keep provisioning until product flips the env to launch (mirrors the
 * CMUX_VM_CREATE_ENABLED opt-out convention, inverted to opt-in).
 */
export function isVmProGateEnforced(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return isVmRequireProFlag(env.CMUX_VM_REQUIRE_PRO);
}

/**
 * True when the caller's plan may NOT provision Cloud VMs: the gate is
 * enforced and the plan is not paid. Management verbs (list/rm/exec/ssh/
 * attach) must NOT consult this — only provisioning entry points.
 */
export function isVmProGateBlocked(
  entitlements: Pick<VmEntitlements, "planId">,
  env: Record<string, string | undefined> = process.env,
): boolean {
  return isVmProGateEnforced(env) && !isPaidVmPlan(entitlements.planId);
}

function isVmRequireProFlag(value: string | undefined): boolean {
  if (value === undefined) return false;
  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
    case "enabled":
      return true;
    default:
      return false;
  }
}

function activeVmLimitForPlan(planId: string, env: Record<string, string | undefined>): number {
  const planKey = planId.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`];
  if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`);

  if (planId === "free") {
    // Free users get two machines before the create path becomes the upgrade prompt
    // (vmActiveLimitExceededResponse renders the paywall variant for unpaid plans).
    return positiveInteger(env.CMUX_VM_FREE_MAX_ACTIVE_VMS ?? "3", "CMUX_VM_FREE_MAX_ACTIVE_VMS");
  }

  return positiveInteger(env.CMUX_VM_PAID_MAX_ACTIVE_VMS ?? "15", "CMUX_VM_PAID_MAX_ACTIVE_VMS");
}

function normalizedPlanId(planId: string): string {
  const normalized = planId.trim().toLowerCase();
  return normalized || "free";
}

function normalizedOptionalString(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

function positiveInteger(raw: string, key: string): number {
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${key} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${key} must be a positive integer`);
  return parsed;
}
