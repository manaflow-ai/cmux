// Monthly allowances of the personal plans, measured on the durable runtime
// meter (`cloud_vm_runtime_intervals`) and reset by the subscription's own
// billing period, whichever store sold it (web checkout or the App Store).
//
// Go counts VM-seconds of its one fixed machine shape (goUsage.ts). Pro and
// Max count compute-seconds: a running machine draws one compute unit per
// vCPU, or per 2 GB of memory when its memory is larger, every second. Pro and
// Max also cap the total disk of their saved machines, because a paused
// machine keeps its disk. Legacy lifetime grants, operator grants, and Team are not
// recurring personal subscriptions and have no allowance here; an operator
// grant to a user who also holds a Pro or Max subscription is metered by that
// subscription. A machine is metered at its current recorded shape, so a
// resize also re-rates the period's earlier runtime of that machine.

import { and, desc, eq, gt, inArray, isNull, lt, ne, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudVmRuntimeIntervals, cloudVms, stripeSubscriptions } from "../../db/schema";
import { activeAppleEntitlementForUser } from "../billing/apple/entitlement";
import type { PersonalPlanId } from "../billing/pro";
import { planItem } from "../billing/subscriptionItems";
import { maxDiskMbForPlan } from "./entitlements";
import {
  PLAN_MACHINE_MEMORY_MB,
  VM_DISK_MB_DEFAULT,
  VM_MEMORY_MB_PER_VCPU,
  hasVmResourceReservationMetadata,
  vcpusForMemoryMb,
  vmResourceReservationFromMetadata,
  type VmResourceReservation,
} from "./machineSpec";

const PLAN_RANK: Readonly<Record<PersonalPlanId, number>> = { go: 1, pro: 2, max: 3 };
const PERSONAL_PLANS = Object.keys(PLAN_RANK) as PersonalPlanId[];
/** Statuses whose period the plan still runs on (mirrors ACTIVE_STRIPE_PRO_STATUSES). */
const STRIPE_PLAN_STATUSES = ["active", "trialing", "past_due"] as const;
const APPLE_PERIOD_FALLBACK_MS = 31 * 24 * 60 * 60 * 1000;

export type BudgetPlanId = "pro" | "max";

/**
 * What one month of Pro and Max includes. One compute-hour is 1 vCPU with
 * 2 GB of memory running for one hour. The numbers keep the worst case (the
 * whole allowance used and the whole disk kept for the month) under 70% of a
 * month's web net revenue ($50 Pro, $200 Max; App Store net is higher) at the
 * machine provider's list rates: a compute-hour costs $0.04032 + 2 x $0.0129
 * = $0.06612 and disk $0.063 per GiB-month.
 *   Pro: 375 x $0.06612 + 160 x $0.063 = $24.80 + $10.08 = $34.88 (69.8%)
 *   Max: 1500 x $0.06612 + 640 x $0.063 = $99.18 + $40.32 = $139.50 (69.8%)
 * The default 4 vCPU / 8 GB machine draws 4 units, so Pro is about 94 hours of
 * it a month and Max about 375.
 */
export const PLAN_BUDGETS: Readonly<Record<BudgetPlanId, { readonly computeHours: number; readonly storageMb: number }>> = {
  pro: { computeHours: 375, storageMb: 160 * 1024 },
  max: { computeHours: 1500, storageMb: 640 * 1024 },
};

/**
 * The Pro and Max allowances are off unless `CMUX_VM_PLAN_BUDGETS=on`. The
 * pricing page promises no hour limits, so by default no Pro or Max user gets
 * a compute-hour or disk limit and the 402 refusal never fires. Go's hours are
 * always enforced.
 */
export function planBudgetsEnforced(env: Record<string, string | undefined> = process.env): boolean {
  return env.CMUX_VM_PLAN_BUDGETS?.trim().toLowerCase() === "on";
}

const DAY_MS = 24 * 60 * 60 * 1000;
/** A billed period up to this long is one allowance window (a monthly plan). */
const SINGLE_WINDOW_MAX_MS = 35 * DAY_MS;
/** A final window shorter than this joins the window before it. */
const MIN_FINAL_WINDOW_MS = 7 * DAY_MS;

/** `start` plus whole calendar months, with the day clamped to the month's last day. */
function addUtcMonths(start: Date, months: number): Date {
  const year = start.getUTCFullYear();
  const month = start.getUTCMonth() + months;
  const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const result = new Date(start);
  result.setUTCDate(1);
  result.setUTCFullYear(year, month, Math.min(start.getUTCDate(), lastDay));
  return result;
}

/**
 * The allowance window that contains `now`. A billed period up to 35 days
 * (monthly) is one window; a longer one (yearly) resets every calendar month
 * from its start, and a final remainder under 7 days joins the window before
 * it. The window that reaches `billedEnd` extends to `accessEnd`, so a grace
 * period counts against the last billed window instead of opening a new one.
 */
export function monthlyAllowanceWindow(
  start: Date,
  billedEnd: Date,
  accessEnd: Date,
  now: Date,
): { start: Date; end: Date } {
  const lastEnd = accessEnd > billedEnd ? accessEnd : billedEnd;
  if (billedEnd.getTime() - start.getTime() <= SINGLE_WINDOW_MAX_MS) return { start, end: lastEnd };
  let windowStart = start;
  for (let month = 1; ; month += 1) {
    const next = addUtcMonths(start, month);
    if (billedEnd.getTime() - next.getTime() < MIN_FINAL_WINDOW_MS) return { start: windowStart, end: lastEnd };
    if (next > now) return { start: windowStart, end: next };
    windowStart = next;
  }
}

export function isBudgetPlanId(planId: string | null | undefined): planId is BudgetPlanId {
  return planId === "pro" || planId === "max";
}

export type PersonalBillingPeriod = {
  readonly planId: PersonalPlanId;
  readonly source: "stripe" | "apple";
  /** Null when the source has no usable current period (a reconcile is pending). */
  readonly period: {
    readonly start: Date;
    /** Access ends here (an App Store grace period extends past the billed end). */
    readonly end: Date;
    /** The paid period ends here. */
    readonly billedEnd: Date;
  } | null;
};

function usablePeriod(start: Date | null, end: Date | null, now: Date, billedEnd: Date | null = end): PersonalBillingPeriod["period"] {
  if (!start || !end || start >= end || now >= end) return null;
  return { start, end, billedEnd: billedEnd && billedEnd > start ? billedEnd : end };
}

/** Stripe's period start: the plan item's, else the subscription's (seconds since epoch). */
export function subscriptionPeriodStart(raw: Record<string, unknown> | null): Date | null {
  const item = planItem(raw as { items?: { data?: Array<{ current_period_start?: unknown; price?: { recurring?: { usage_type?: string | null } | null } | null }> } } | null);
  const value = item?.current_period_start ?? raw?.current_period_start;
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? new Date(value * 1000) : null;
}

function isMissingDatabase(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}

async function stripePersonalPeriod(
  userId: string,
  statuses: readonly string[],
  now: Date,
): Promise<PersonalBillingPeriod | null> {
  const rows = await cloudDb().select({
    plan: stripeSubscriptions.plan,
    raw: stripeSubscriptions.raw,
    currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
  }).from(stripeSubscriptions).where(and(
    eq(stripeSubscriptions.stackUserId, userId),
    eq(stripeSubscriptions.scope, "user"),
    inArray(stripeSubscriptions.plan, PERSONAL_PLANS),
    inArray(stripeSubscriptions.status, [...statuses]),
    // Legacy lifetime grants are one-time purchases stored as an active Pro row.
    sql`${stripeSubscriptions.id} not like 'founders\\_%'`,
    sql`coalesce(${stripeSubscriptions.raw}->'metadata'->>'founders_edition', '') <> 'true'`,
  )).orderBy(desc(stripeSubscriptions.updatedAt)).limit(10);
  let best: (typeof rows)[number] | null = null;
  for (const row of rows) {
    if (!best || PLAN_RANK[row.plan as PersonalPlanId] > PLAN_RANK[best.plan as PersonalPlanId]) best = row;
  }
  if (!best) return null;
  return {
    planId: best.plan as PersonalPlanId,
    source: "stripe",
    period: usablePeriod(subscriptionPeriodStart(best.raw as Record<string, unknown> | null), best.currentPeriodEnd, now),
  };
}

/**
 * An App Store subscription's period runs from its newest transaction's
 * purchase date to its expiry; a grace period extends the same period, so
 * runtime during billing retry still counts against it. Matches the Go
 * capacity trigger in the database.
 */
async function applePersonalPeriod(userId: string, now: Date): Promise<PersonalBillingPeriod | null> {
  const row = await activeAppleEntitlementForUser(userId, { now });
  if (!row || !(row.planId in PLAN_RANK)) return null;
  const expires = row.expiresAt;
  const end = expires && row.gracePeriodExpiresAt && row.gracePeriodExpiresAt > expires
    ? row.gracePeriodExpiresAt
    : expires ?? row.gracePeriodExpiresAt;
  const start = row.purchaseDate ?? (expires ? new Date(expires.getTime() - APPLE_PERIOD_FALLBACK_MS) : null);
  return { planId: row.planId as PersonalPlanId, source: "apple", period: usablePeriod(start, end, now, expires) };
}

/**
 * The recurring personal subscription that sets the user's plan and its
 * current billing period: the higher plan of the web and App Store
 * subscriptions, the web one on a tie. Null when the user has neither.
 */
export async function personalBillingPeriod(
  userId: string,
  options: { readonly now?: Date; readonly stripeStatuses?: readonly string[] } = {},
): Promise<PersonalBillingPeriod | null> {
  const now = options.now ?? new Date();
  const [stripe, apple] = await Promise.all([
    stripePersonalPeriod(userId, options.stripeStatuses ?? STRIPE_PLAN_STATUSES, now),
    applePersonalPeriod(userId, now),
  ]);
  if (stripe && apple) {
    if (PLAN_RANK[apple.planId] !== PLAN_RANK[stripe.planId]) {
      return PLAN_RANK[apple.planId] > PLAN_RANK[stripe.planId] ? apple : stripe;
    }
    // Same plan from both stores: the one with a usable period meters it,
    // like the database guard, which falls back to the App Store.
    return stripe.period || !apple.period ? stripe : apple;
  }
  return stripe ?? apple;
}

/** Seconds of the intervals that fall inside the period, up to `now`. */
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

/**
 * Compute units a machine draws while it runs. A machine without a recorded
 * shape counts as the default paid machine until reconciliation records it.
 */
export function computeUnitsForReservation(reservation: Pick<VmResourceReservation, "vcpus" | "memoryMb"> | null): number {
  if (!reservation) return vcpusForMemoryMb(PLAN_MACHINE_MEMORY_MB);
  return Math.max(reservation.vcpus, Math.ceil(reservation.memoryMb / VM_MEMORY_MB_PER_VCPU));
}

/** The recorded machine shape, or null for a legacy row without one. */
function recordedReservation(metadata: Record<string, unknown> | null): VmResourceReservation | null {
  return hasVmResourceReservationMetadata(metadata) ? vmResourceReservationFromMetadata(metadata) : null;
}

export type PlanBudgetUsage = {
  readonly planId: BudgetPlanId;
  readonly periodStart: Date;
  /** The allowance resets here. */
  readonly periodEnd: Date;
  readonly includedComputeSeconds: number;
  readonly usedComputeSeconds: number;
  readonly remainingComputeSeconds: number;
  readonly storageBudgetMb: number;
  /** Disk of every provisioning, running, or paused machine, by VM id. */
  readonly retainedDiskMb: ReadonlyMap<string, number>;
  readonly retainedStorageMb: number;
};

/** Team-billed machines draw from the team's plan, not this allowance. */
const personalMachine = or(isNull(cloudVms.billingPlanId), ne(cloudVms.billingPlanId, "team"));

/**
 * The caller's Pro or Max allowance this billing period, or null when no
 * allowance applies (no recurring Pro or Max subscription, an unusable
 * period, or a deployment without a database). Null never refuses.
 */
export async function getPlanBudgetUsage(userId: string, now = new Date()): Promise<PlanBudgetUsage | null> {
  if (!planBudgetsEnforced()) return null;
  let billing: PersonalBillingPeriod | null;
  try {
    billing = await personalBillingPeriod(userId, { now });
  } catch (error) {
    if (isMissingDatabase(error)) return null;
    throw error;
  }
  if (!billing || !isBudgetPlanId(billing.planId)) return null;
  if (!billing.period) {
    console.warn("[VM] plan allowance skipped: billing period unavailable", { userId, source: billing.source });
    return null;
  }
  const { start: periodStart, end: periodEnd } = monthlyAllowanceWindow(billing.period.start, billing.period.billedEnd, billing.period.end, now);
  const db = cloudDb();
  const [intervals, retained] = await Promise.all([
    db.select({
      startedAt: cloudVmRuntimeIntervals.startedAt,
      endedAt: cloudVmRuntimeIntervals.endedAt,
      metadata: cloudVms.providerMetadata,
    }).from(cloudVmRuntimeIntervals)
      .innerJoin(cloudVms, eq(cloudVms.id, cloudVmRuntimeIntervals.vmId))
      .where(and(
        eq(cloudVmRuntimeIntervals.userId, userId),
        lt(cloudVmRuntimeIntervals.startedAt, periodEnd),
        or(isNull(cloudVmRuntimeIntervals.endedAt), gt(cloudVmRuntimeIntervals.endedAt, periodStart)),
        personalMachine,
      )),
    db.select({ id: cloudVms.id, metadata: cloudVms.providerMetadata }).from(cloudVms).where(and(
      eq(cloudVms.userId, userId),
      inArray(cloudVms.status, ["provisioning", "running", "paused"]),
      personalMachine,
    )),
  ]);
  const usedComputeSeconds = intervals.reduce((sum, interval) =>
    sum + runtimeSecondsWithinPeriod([interval], periodStart, periodEnd, now) *
      computeUnitsForReservation(recordedReservation(interval.metadata)), 0);
  // A legacy machine reserves the provider's disk ceiling until it is
  // measured; the plan's per-machine maximum is the most it can hold.
  const machineDiskCeilingMb = maxDiskMbForPlan(billing.planId);
  const retainedDiskMb = new Map(retained.map((vm) => [
    vm.id,
    Math.min(recordedReservation(vm.metadata)?.diskMb ?? VM_DISK_MB_DEFAULT, machineDiskCeilingMb),
  ]));
  const budget = PLAN_BUDGETS[billing.planId];
  const includedComputeSeconds = budget.computeHours * 3600;
  return {
    planId: billing.planId,
    periodStart,
    periodEnd,
    includedComputeSeconds,
    usedComputeSeconds,
    remainingComputeSeconds: Math.max(0, includedComputeSeconds - usedComputeSeconds),
    storageBudgetMb: budget.storageMb,
    retainedDiskMb,
    retainedStorageMb: [...retainedDiskMb.values()].reduce((sum, mb) => sum + mb, 0),
  };
}
