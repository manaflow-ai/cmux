import type { AuthedUser } from "./auth";
import type { BillingCustomerType } from "./billingGateway";
import { PRO_PLAN_ID, TEAM_PLAN_ID } from "../billing/pro";

export type VmEntitlements = {
  readonly planId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly maxActiveVms: number;
  /** ISO-8601 timestamp the no-card Pro trial started, or null if never started. */
  readonly vmTrialStartedAt: string | null;
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
    vmTrialStartedAt: user.vmTrialStartedAt ?? null,
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

/** Length of the no-card Pro trial in ms (CMUX_VM_TRIAL_DAYS, default 7). */
export function vmTrialDurationMs(
  env: Record<string, string | undefined> = process.env,
): number {
  const days = Number.parseInt(env.CMUX_VM_TRIAL_DAYS ?? "", 10);
  const safeDays = Number.isFinite(days) && days > 0 ? days : 7;
  return safeDays * 24 * 60 * 60 * 1000;
}

export type VmTrialState = {
  /** Whether a trial has ever been started for this user. */
  readonly started: boolean;
  /** Within the trial window right now. */
  readonly active: boolean;
  /** Started but the window has elapsed. */
  readonly expired: boolean;
  /** Whole days remaining while active (0 once expired/never-started). */
  readonly daysRemaining: number;
  /** ISO end of the trial window, or null if never started. */
  readonly endsAt: string | null;
};

/** Interpret a stored trial-start timestamp against the current instant. */
export function resolveVmTrialState(
  vmTrialStartedAt: string | null | undefined,
  env: Record<string, string | undefined> = process.env,
  nowMs: number = Date.now(),
): VmTrialState {
  const startedMs = vmTrialStartedAt ? Date.parse(vmTrialStartedAt) : NaN;
  if (!Number.isFinite(startedMs)) {
    return { started: false, active: false, expired: false, daysRemaining: 0, endsAt: null };
  }
  const endMs = startedMs + vmTrialDurationMs(env);
  const active = nowMs < endMs;
  const daysRemaining = active ? Math.max(0, Math.ceil((endMs - nowMs) / (24 * 60 * 60 * 1000))) : 0;
  return {
    started: true,
    active,
    expired: !active,
    daysRemaining,
    endsAt: new Date(endMs).toISOString(),
  };
}

/**
 * Reason-coded provisioning decision for a Cloud VM entry point.
 * - "allowed": paid plan, active trial, or the gate is not enforced.
 * - "trial_available": free user with no trial yet — the route should start
 *   the no-card trial (persist the timestamp) and then proceed.
 * - "trial_expired": free user whose trial window elapsed — show the upgrade
 *   wall ("add a card to keep Cloud VMs").
 */
export type VmProGateDecision = "allowed" | "trial_available" | "trial_expired";

export function resolveVmProGateDecision(
  entitlements: Pick<VmEntitlements, "planId" | "vmTrialStartedAt">,
  env: Record<string, string | undefined> = process.env,
  nowMs: number = Date.now(),
): VmProGateDecision {
  if (!isVmProGateEnforced(env)) return "allowed";
  if (isPaidVmPlan(entitlements.planId)) return "allowed";
  const trial = resolveVmTrialState(entitlements.vmTrialStartedAt, env, nowMs);
  if (trial.active) return "allowed";
  if (trial.expired) return "trial_expired";
  return "trial_available";
}

/**
 * True when the caller may NOT provision Cloud VMs *without any further action*
 * — i.e. the trial window has elapsed. "trial_available" is NOT blocked: the
 * route starts the no-card trial and proceeds. Management verbs
 * (list/rm/exec/ssh/attach) must NOT consult this — only provisioning entry
 * points.
 */
export function isVmProGateBlocked(
  entitlements: Pick<VmEntitlements, "planId" | "vmTrialStartedAt">,
  env: Record<string, string | undefined> = process.env,
  nowMs: number = Date.now(),
): boolean {
  return resolveVmProGateDecision(entitlements, env, nowMs) === "trial_expired";
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
    return positiveInteger(env.CMUX_VM_FREE_MAX_ACTIVE_VMS ?? "5", "CMUX_VM_FREE_MAX_ACTIVE_VMS");
  }

  return positiveInteger(env.CMUX_VM_PAID_MAX_ACTIVE_VMS ?? "10", "CMUX_VM_PAID_MAX_ACTIVE_VMS");
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
