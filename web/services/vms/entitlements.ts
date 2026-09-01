import type { AuthedUser } from "./auth";
import type { BillingCustomerType } from "./billingGateway";
import { FOUNDERS_PLAN_ID, PRO_PLAN_ID, TEAM_PLAN_ID } from "../billing/pro";

export type VmEntitlements = {
  readonly planId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly maxActiveVms: number;
};

export type VmEntitlementOptions = {
  readonly requestedBillingTeamId?: string | null;
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
  const configuredDefaultPlan = env.CMUX_VM_DEFAULT_PLAN;
  // A deployment-wide default is useful for local/demo fixtures, but it must
  // never grant a paid entitlement to an account with no billing metadata in
  // the normal fail-closed mode. Reusing the same explicit escape hatch keeps
  // this fallback from becoming a second permissive configuration path.
  const defaultPlan = configuredDefaultPlan &&
      (isVmFreeProvisioningAllowed(env) || !isPaidVmPlan(configuredDefaultPlan))
    ? configuredDefaultPlan
    : "free";
  const planId = normalizedPlanId(billing.billingPlanId ?? defaultPlan);
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

  // No team at all (accounts that predate personal-team auto-create): bill
  // the user directly. Every billing surface (Stack items, credits, plan
  // metadata) supports user-scoped customers, so provisioning verbs must not
  // dead-end on a 409 the caller has no way to resolve.
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
export const VM_MEMORY_OPTIONS_MB: readonly number[] = [2048, 4096, 8192, 16384, 24576, 32768];

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
    // The free machine is the product demo: one full-size computer, not a
    // cut-down teaser. The paywall is the 7-day access window and the
    // machine count, never the machine's usefulness.
    return positiveInteger(env.CMUX_VM_FREE_MAX_MEMORY_MB ?? "24576", "CMUX_VM_FREE_MAX_MEMORY_MB");
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
      ? positiveInteger(env.CMUX_VM_FREE_DEFAULT_MEMORY_MB ?? "24576", "CMUX_VM_FREE_DEFAULT_MEMORY_MB")
      : positiveInteger(env.CMUX_VM_PAID_DEFAULT_MEMORY_MB ?? "24576", "CMUX_VM_PAID_DEFAULT_MEMORY_MB");
  return Math.min(raw, maxMemoryMbForPlan(planId, env));
}

export function maxActiveVmsForPlan(
  planId: string | null | undefined,
  env: Record<string, string | undefined> = process.env,
): number {
  return activeVmLimitForPlan(normalizedPlanId(planId ?? ""), env);
}

/**
 * How long a free-plan machine stays reachable after it is created, in days.
 * After the window the machine (and its data) is preserved, but every access
 * verb (attach, ssh, exec, ports, sessions) requires a paid plan; list/status/
 * delete keep working so the machine is visible and disposable. 0 disables
 * the window entirely (env kill switch).
 */
export function vmFreeAccessWindowDays(
  env: Record<string, string | undefined> = process.env,
): number {
  const raw = env.CMUX_VM_FREE_ACCESS_WINDOW_DAYS;
  if (raw === undefined || !raw.trim()) return 7;
  const parsed = Number.parseInt(raw.trim(), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`CMUX_VM_FREE_ACCESS_WINDOW_DAYS must be a non-negative integer, got: ${raw}`);
  }
  return parsed;
}

/**
 * Whether the caller's CURRENT plan has outlived the free access window for a
 * machine created at `createdAt`. Deliberately keyed on the caller's plan, not
 * the plan recorded at create time: upgrading to Pro unlocks every machine the
 * user already has.
 */
export function isVmFreeAccessExpired(
  callerPlanId: string | null | undefined,
  createdAt: Date | number | null | undefined,
  env: Record<string, string | undefined> = process.env,
  nowMs: number = Date.now(),
): boolean {
  if (isPaidVmPlan(normalizedPlanId(callerPlanId ?? ""))) return false;
  const windowDays = vmFreeAccessWindowDays(env);
  if (windowDays <= 0) return false;
  const createdMs = createdAt instanceof Date ? createdAt.getTime() : createdAt;
  if (typeof createdMs !== "number" || !Number.isFinite(createdMs)) return false;
  return nowMs - createdMs > windowDays * 24 * 60 * 60 * 1000;
}

/** A paid Cloud VM plan is Pro, Team, or Founder's Edition; everything else (free) is not. */
export function isPaidVmPlan(planId: string): boolean {
  const normalized = normalizedPlanId(planId);
  return normalized === PRO_PLAN_ID || normalized === TEAM_PLAN_ID || normalized === FOUNDERS_PLAN_ID;
}

/**
 * Whether Cloud VM provisioning is gated behind a paid plan.
 *
 * The safe default is enforced. `CMUX_VM_ALLOW_FREE_PROVISIONING=1` is an
 * explicit operator escape hatch for demos or a controlled rollback. The
 * historical `CMUX_VM_REQUIRE_PRO=0` spelling remains a compatibility alias
 * when the new switch is absent; every other unset, malformed, or truthy
 * value keeps the gate closed to free plans.
 */
export function isVmProGateEnforced(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return !isVmFreeProvisioningAllowed(env);
}

/**
 * Whether an operator has explicitly opted into free Cloud VM provisioning.
 * Keep this as the shared policy predicate so the gate and free active limit
 * cannot drift into different permissive states.
 */
export function isVmFreeProvisioningAllowed(
  env: Record<string, string | undefined> = process.env,
): boolean {
  // The new name is authoritative when present. A value must be explicitly
  // truthy; typos and explicit false values fail closed.
  if (env.CMUX_VM_ALLOW_FREE_PROVISIONING !== undefined) {
    return isVmTruthyFlag(env.CMUX_VM_ALLOW_FREE_PROVISIONING);
  }

  // Preserve the old opt-in gate's false values as a migration alias. An
  // absent or malformed legacy value now fails closed instead of shipping dark.
  const legacy = env.CMUX_VM_REQUIRE_PRO;
  return legacy !== undefined && isVmFalseFlag(legacy);
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

function isVmTruthyFlag(value: string | undefined): boolean {
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

function isVmFalseFlag(value: string | undefined): boolean {
  if (value === undefined) return false;
  switch (value.trim().toLowerCase()) {
    case "0":
    case "false":
    case "no":
    case "off":
    case "disabled":
      return true;
    default:
      return false;
  }
}

function activeVmLimitForPlan(planId: string, env: Record<string, string | undefined>): number {
  const planKey = planId.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  if (!isPaidVmPlan(planId)) {
    // Cloud machines are a paid feature. Keep every non-paid/unknown plan at
    // zero unless the same explicit escape hatch that disables the Pro gate is
    // set; this prevents a stale `CMUX_VM_FREE_MAX_ACTIVE_VMS` (or a plan-
    // specific override) from reopening provisioning by configuration drift.
    if (!isVmFreeProvisioningAllowed(env)) return 0;
    const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`];
    if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`);
    return nonNegativeInteger(env.CMUX_VM_FREE_MAX_ACTIVE_VMS ?? "0", "CMUX_VM_FREE_MAX_ACTIVE_VMS");
  }

  const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`];
  if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`);
  return positiveInteger(env.CMUX_VM_PAID_MAX_ACTIVE_VMS ?? "5", "CMUX_VM_PAID_MAX_ACTIVE_VMS");
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

function nonNegativeInteger(raw: string, key: string): number {
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${key} must be a non-negative integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${key} must be a non-negative integer`);
  return parsed;
}
