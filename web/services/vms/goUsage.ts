import { and, count, desc, eq, gt, inArray, isNull, lt, or } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms, cloudVmRuntimeIntervals, stripeSubscriptions } from "../../db/schema";

export const GO_INCLUDED_VM_HOURS = 40;
export const GO_INCLUDED_VM_SECONDS = GO_INCLUDED_VM_HOURS * 3600;
/** Two retained machines in total, at most one of them running. */
export const GO_SAVED_VM_LIMIT = 2;

export type GoVmUsage = {
  readonly periodStart: Date;
  readonly periodEnd: Date;
  readonly usedSeconds: number;
  readonly remainingSeconds: number;
  readonly savedVms: number;
};

export function runtimeSecondsWithinPeriod(
  intervals: readonly { startedAt: Date; endedAt: Date | null }[],
  periodStart: Date,
  periodEnd: Date,
  now: Date,
): number {
  const end = Math.min(now.getTime(), periodEnd.getTime());
  return Math.ceil(intervals.reduce((sum, interval) => sum + Math.max(0,
    Math.min(interval.endedAt?.getTime() ?? end, end) -
      Math.max(interval.startedAt.getTime(), periodStart.getTime()),
  ), 0) / 1000);
}

export function subscriptionPeriodStart(raw: Record<string, unknown> | null): Date | null {
  const items = raw?.items as { data?: Array<{ current_period_start?: unknown }> } | undefined;
  const value = items?.data?.[0]?.current_period_start ?? raw?.current_period_start;
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? new Date(value * 1000) : null;
}

/** A renewal resets the allowance using Stripe's billing period, not UTC months. */
export async function getGoVmUsage(userId: string, now = new Date()): Promise<GoVmUsage | null> {
  const db = cloudDb();
  const [subscription] = await db.select().from(stripeSubscriptions).where(and(
    eq(stripeSubscriptions.stackUserId, userId),
    eq(stripeSubscriptions.scope, "user"),
    inArray(stripeSubscriptions.status, ["active", "trialing"]),
  )).orderBy(desc(stripeSubscriptions.updatedAt)).limit(1);
  if (!subscription) return { periodStart: now, periodEnd: now, usedSeconds: GO_INCLUDED_VM_SECONDS, remainingSeconds: 0, savedVms: 0 };
  if (subscription.plan !== "go") return null;
  const periodStart = subscriptionPeriodStart(subscription.raw);
  const periodEnd = subscription.currentPeriodEnd;
  if (!periodStart || !periodEnd || periodStart >= periodEnd || now >= periodEnd) {
    throw new Error("Go billing period is unavailable; reconcile the subscription before granting runtime");
  }
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
  return { periodStart, periodEnd, usedSeconds,
    remainingSeconds: Math.max(0, GO_INCLUDED_VM_SECONDS - usedSeconds),
    savedVms: Number(retained[0]?.total ?? 0) };
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
