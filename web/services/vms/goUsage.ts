import { and, count, eq, gt, inArray, isNull, lt, or } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms, cloudVmRuntimeIntervals } from "../../db/schema";
import { personalBillingPeriod, runtimeSecondsWithinPeriod, subscriptionPeriodStart } from "./planUsage";

export { runtimeSecondsWithinPeriod, subscriptionPeriodStart };

export const GO_INCLUDED_VM_HOURS = 40;
export const GO_INCLUDED_VM_SECONDS = GO_INCLUDED_VM_HOURS * 3600;
/** Two retained machines in total, at most one of them running. */
export const GO_SAVED_VM_LIMIT = 2;
/**
 * The iOS Pro free trial runs on Go limits with a smaller allowance: one
 * retained machine and 20 VM-hours for the whole trial (the trial is one
 * billing period). Same constants as the database guard.
 */
export const TRIAL_INCLUDED_VM_HOURS = 20;
export const TRIAL_INCLUDED_VM_SECONDS = TRIAL_INCLUDED_VM_HOURS * 3600;
export const TRIAL_SAVED_VM_LIMIT = 1;

export type GoVmUsage = {
  readonly periodStart: Date;
  readonly periodEnd: Date;
  readonly usedSeconds: number;
  readonly remainingSeconds: number;
  readonly savedVms: number;
  /** The allowance of this period: Go's, or the trial's. */
  readonly includedSeconds: number;
  readonly savedVmLimit: number;
  /** The period is the iOS Pro free trial. */
  readonly trial: boolean;
};

/**
 * A renewal resets the allowance using the subscription's own billing period
 * (web checkout or the App Store), not UTC months. Null when the user's plan
 * is not Go; an exhausted allowance when no Go subscription is active.
 */
export async function getGoVmUsage(userId: string, now = new Date()): Promise<GoVmUsage | null> {
  const db = cloudDb();
  const subscription = await personalBillingPeriod(userId, { now, stripeStatuses: ["active", "trialing"] });
  if (!subscription) {
    return {
      periodStart: now, periodEnd: now, usedSeconds: GO_INCLUDED_VM_SECONDS, remainingSeconds: 0, savedVms: 0,
      includedSeconds: GO_INCLUDED_VM_SECONDS, savedVmLimit: GO_SAVED_VM_LIMIT, trial: false,
    };
  }
  if (subscription.planId !== "go") return null;
  if (!subscription.period) {
    throw new Error("Go billing period is unavailable; reconcile the subscription before granting runtime");
  }
  const { start: periodStart, end: periodEnd } = subscription.period;
  const [intervals, retained] = await Promise.all([
    db.select({ startedAt: cloudVmRuntimeIntervals.startedAt, endedAt: cloudVmRuntimeIntervals.endedAt })
      .from(cloudVmRuntimeIntervals).where(and(
        eq(cloudVmRuntimeIntervals.userId, userId),
        lt(cloudVmRuntimeIntervals.startedAt, periodEnd),
        or(isNull(cloudVmRuntimeIntervals.endedAt), gt(cloudVmRuntimeIntervals.endedAt, periodStart)),
      )),
    db.select({ total: count() }).from(cloudVms).where(and(
      eq(cloudVms.userId, userId), inArray(cloudVms.status, ["running", "provisioning", "paused"]),
    )),
  ]);
  const usedSeconds = runtimeSecondsWithinPeriod(intervals, periodStart, periodEnd, now);
  const trial = subscription.trial === true;
  const includedSeconds = trial ? TRIAL_INCLUDED_VM_SECONDS : GO_INCLUDED_VM_SECONDS;
  return { periodStart, periodEnd, usedSeconds,
    remainingSeconds: Math.max(0, includedSeconds - usedSeconds),
    savedVms: Number(retained[0]?.total ?? 0),
    includedSeconds,
    savedVmLimit: trial ? TRIAL_SAVED_VM_LIMIT : GO_SAVED_VM_LIMIT,
    trial };
}

/**
 * Whether the person's Go entitlement is the iOS Pro free trial, so limit
 * messages name "Pro trial" and never Go. Same rule as getGoVmUsage and the
 * database guard. Read only when a Go limit answers a request; a failed read
 * is not a trial.
 */
export async function isGoTrialUser(userId: string, now = new Date()): Promise<boolean> {
  try {
    const subscription = await personalBillingPeriod(userId, { now, stripeStatuses: ["active", "trialing"] });
    return subscription?.planId === "go" && subscription.trial === true;
  } catch {
    return false;
  }
}

/** Drizzle wraps PostgreSQL constraints; inspect only the known public limits. */
export function goCapacityConstraint(cause: unknown): "saved" | "active" | "hours" | "period" | null {
  const seen = new Set<unknown>();
  while (cause && typeof cause === "object" && !seen.has(cause)) {
    seen.add(cause);
    const value = cause as { constraint?: string; cause?: unknown; constraint_name?: string };
    const name = value.constraint ?? value.constraint_name;
    if (name === "cmux_go_saved_limit") return "saved";
    if (name === "cmux_go_active_limit") return "active";
    if (name === "cmux_go_hours_limit") return "hours";
    if (name === "cmux_go_period_unavailable") return "period";
    cause = value.cause;
  }
  return null;
}
