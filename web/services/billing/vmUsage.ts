import { and, eq, inArray } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
} from "./pro";
import {
  getTeamActiveComputeHours,
  type BillingPeriod,
} from "../vms/usage";
import { billingPeriodThrough } from "../vms/usageMath";
export { billingPeriodThrough } from "../vms/usageMath";

/** The allowance currently sold for the Pro plan. */
export const PRO_INCLUDED_COMPUTE_HOURS = 20;

export type VmUsageStatus = {
  readonly billingTeamId: string | null;
  readonly periodStart: string;
  readonly periodEnd: string;
  readonly activeComputeHours: number;
  readonly includedComputeHours: number;
  readonly overageComputeHours: number;
};

type UsageSubscription = {
  readonly currentPeriodEnd: Date | null;
  readonly raw: unknown;
};

/**
 * Returns the current Stripe period when the webhook stored complete period
 * data. Older rows fall back to the UTC calendar month until they renew.
 */
export function resolveVmBillingPeriod(input: {
  readonly now?: Date;
  readonly currentPeriodEnd?: Date | null;
  readonly raw?: unknown;
}): BillingPeriod {
  const now = validDate(input.now) ? input.now! : new Date();
  const raw = record(input.raw);
  const items = record(raw?.items);
  const itemData = items?.data;
  const firstItem = Array.isArray(itemData) ? record(itemData[0]) : null;
  const start = periodDate(raw?.current_period_start) ?? periodDate(firstItem?.current_period_start);
  const end = periodDate(raw?.current_period_end) ??
    periodDate(firstItem?.current_period_end) ??
    (validDate(input.currentPeriodEnd) ? input.currentPeriodEnd : null);
  if (start && end && end.getTime() > start.getTime()) {
    return { start, end };
  }

  return utcCalendarMonth(now);
}

export function emptyVmUsageStatus(input: {
  readonly now?: Date;
  readonly billingTeamId?: string | null;
  readonly includedComputeHours?: number;
  readonly period?: BillingPeriod;
} = {}): VmUsageStatus {
  const period = input.period ?? utcCalendarMonth(validDate(input.now) ? input.now! : new Date());
  const includedComputeHours = finiteNonNegative(input.includedComputeHours ?? 0);
  return {
    billingTeamId: input.billingTeamId?.trim() || null,
    periodStart: period.start.toISOString(),
    periodEnd: period.end.toISOString(),
    activeComputeHours: 0,
    includedComputeHours,
    overageComputeHours: 0,
  };
}

/** Loads the usage scope used by the existing billing plan endpoint. */
export async function getVmUsageStatus(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly isPro: boolean;
  readonly now?: Date;
}): Promise<VmUsageStatus> {
  const billingTeamId = input.billingTeamId?.trim() || input.userId;
  const includedComputeHours = input.isPro ? PRO_INCLUDED_COMPUTE_HOURS : 0;
  const now = validDate(input.now) ? input.now! : new Date();
  let period = utcCalendarMonth(now);

  try {
    const subscription = await loadUsageSubscription({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
    });
    period = resolveVmBillingPeriod({
      now,
      currentPeriodEnd: subscription?.currentPeriodEnd,
      raw: subscription?.raw,
    });
    const usagePeriod = billingPeriodThrough(period, now);
    const activeComputeHours = usagePeriod
      ? await getTeamActiveComputeHours({ billingTeamId, period: usagePeriod })
      : 0;
    const overageComputeHours = Math.max(0, activeComputeHours - includedComputeHours);
    return {
      billingTeamId,
      periodStart: period.start.toISOString(),
      periodEnd: period.end.toISOString(),
      activeComputeHours,
      includedComputeHours,
      overageComputeHours: roundHours(overageComputeHours),
    };
  } catch (error) {
    // A rolling deployment can briefly run before the new table exists. Keep
    // the existing entitlement response available and show zero usage until
    // the migration is applied. Other database failures remain visible.
    if (isUsageDatabaseUnavailable(error)) {
      return emptyVmUsageStatus({
        now,
        billingTeamId,
        includedComputeHours,
        period,
      });
    }
    throw error;
  }
}

async function loadUsageSubscription(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
}): Promise<UsageSubscription | null> {
  const teamId = input.billingTeamId?.trim();
  if (teamId && teamId !== input.userId) {
    const teamSubscription = await loadUsageSubscriptionForScope(and(
      eq(stripeSubscriptions.stackTeamId, teamId),
      eq(stripeSubscriptions.scope, "team"),
      eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
    ));
    if (teamSubscription) return teamSubscription;
  }

  // Stack personal teams own VM rows even when Stripe owns the Pro
  // subscription at user scope. Use that user subscription's billing period
  // when the selected team has no Team subscription of its own.
  return loadUsageSubscriptionForScope(and(
    eq(stripeSubscriptions.stackUserId, input.userId),
    eq(stripeSubscriptions.scope, "user"),
    eq(stripeSubscriptions.plan, PRO_PLAN_ID),
  ));
}

async function loadUsageSubscriptionForScope(
  scope: ReturnType<typeof and>,
): Promise<UsageSubscription | null> {
  const [row] = await cloudDb()
    .select({
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(and(scope, inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES)))
    .limit(1);
  return row ?? null;
}

function utcCalendarMonth(now: Date): BillingPeriod {
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth();
  return {
    start: new Date(Date.UTC(year, month, 1)),
    end: new Date(Date.UTC(year, month + 1, 1)),
  };
}

function periodDate(value: unknown): Date | null {
  if (value instanceof Date) return validDate(value) ? value : null;
  if (typeof value === "number" || typeof value === "string") {
    const text = String(value).trim();
    if (!text) return null;
    const numeric = Number(text);
    if (Number.isFinite(numeric) && numeric > 0) {
      const epoch = new Date(numeric * 1_000);
      return validDate(epoch) ? epoch : null;
    }
    const parsed = new Date(text);
    return validDate(parsed) ? parsed : null;
  }
  return null;
}

function validDate(value: Date | null | undefined): value is Date {
  return value instanceof Date && Number.isFinite(value.getTime());
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function finiteNonNegative(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function roundHours(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function isUsageDatabaseUnavailable(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { readonly code?: unknown; readonly message?: unknown; readonly cause?: unknown };
  if (candidate.code === "42P01") return true;
  if (candidate.cause && isUsageDatabaseUnavailable(candidate.cause)) return true;
  return typeof candidate.message === "string" && /DATABASE_URL|database config|cloud_vm_state_transitions/i.test(candidate.message);
}
