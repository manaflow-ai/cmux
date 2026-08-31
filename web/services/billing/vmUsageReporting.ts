import { and, eq, inArray } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
} from "./pro";
import { stripe, isStripeBillingConfigured } from "./stripe";
import {
  billingPeriodThrough,
  PRO_INCLUDED_COMPUTE_HOURS,
  resolveVmBillingPeriod,
} from "./vmUsage";
import { getUserPlanActiveComputeHours } from "../vms/usage";

const DEFAULT_REPORT_LIMIT = 1_000;
const DEFAULT_REPORT_CONCURRENCY = 8;

export type StripeUsageClient = {
  readonly billing: {
    readonly meterEvents: {
      readonly create: (params: {
        readonly event_name: string;
        readonly payload: {
          readonly stripe_customer_id: string;
          readonly value: string;
        };
        readonly identifier: string;
        readonly timestamp: number;
      }) => Promise<unknown>;
    };
  };
};

export type VmUsageSubscription = {
  readonly id: string;
  readonly customerId: string;
  readonly stackUserId: string;
  readonly stackTeamId: string | null;
  readonly scope: string;
  readonly plan: string;
  readonly currentPeriodEnd: Date | null;
  readonly raw: unknown;
};

export type VmUsageReportResult = {
  readonly status:
    | "disabled"
    | "unsupported_subscription"
    | "no_overage"
    | "not_configured"
    | "reported";
  readonly subscriptionId?: string;
  readonly billingTeamId?: string;
  readonly activeComputeHours?: number;
  readonly overageComputeHours?: number;
  readonly quantity?: number;
};

export type VmUsageBatchReportResult = {
  readonly enabled: boolean;
  readonly checked: number;
  readonly reported: number;
  readonly skipped: number;
  readonly failed: number;
};

/** Stripe must provision a meter with this event name and Last aggregation. */
export const VM_USAGE_METER_EVENT_NAME = "cmux_vm_active_compute_hours";

/** The rollout switch is deliberately strict and defaults to disabled. */
export function isStripeUsageReportingEnabled(
  environment: Record<string, string | undefined> = process.env,
): boolean {
  return environment.STRIPE_USAGE_REPORTING?.trim() === "1";
}

export function overageComputeHours(
  activeComputeHours: number,
  includedComputeHours = PRO_INCLUDED_COMPUTE_HOURS,
): number {
  if (!Number.isFinite(activeComputeHours) || !Number.isFinite(includedComputeHours)) return 0;
  return roundHours(Math.max(0, activeComputeHours - Math.max(0, includedComputeHours)));
}

/**
 * Reports cumulative overage to a Stripe meter that uses Last aggregation.
 * The deterministic identifier makes an hourly retry idempotent.
 */
export async function reportVmUsageForSubscription(
  subscription: VmUsageSubscription,
  options: {
    readonly now?: Date;
    readonly enabled?: boolean;
    readonly stripeClient?: StripeUsageClient;
    readonly activeHours?: number;
  } = {},
): Promise<VmUsageReportResult> {
  if (!(options.enabled ?? isStripeUsageReportingEnabled())) {
    return { status: "disabled", subscriptionId: subscription.id };
  }
  if (subscription.scope !== "user" || subscription.plan !== PRO_PLAN_ID) {
    return {
      status: "unsupported_subscription",
      subscriptionId: subscription.id,
    };
  }

  const now = validDate(options.now) ? options.now! : new Date();
  const billingTeamId = subscription.stackTeamId?.trim() || subscription.stackUserId;
  const period = resolveVmBillingPeriod({
    now,
    currentPeriodEnd: subscription.currentPeriodEnd,
    raw: subscription.raw,
  });
  const usagePeriod = billingPeriodThrough(period, now);
  const activeComputeHours = options.activeHours ?? (usagePeriod
    ? await getUserPlanActiveComputeHours({
      userId: subscription.stackUserId,
      billingPlanId: PRO_PLAN_ID,
      period: usagePeriod,
    })
    : 0);
  const overageComputeHoursValue = overageComputeHours(activeComputeHours);
  if (overageComputeHoursValue <= 0) {
    return {
      status: "no_overage",
      subscriptionId: subscription.id,
      billingTeamId,
      activeComputeHours,
      overageComputeHours: 0,
    };
  }

  if (!isStripeBillingConfigured() && !options.stripeClient) {
    return {
      status: "not_configured",
      subscriptionId: subscription.id,
      billingTeamId,
      activeComputeHours,
      overageComputeHours: overageComputeHoursValue,
    };
  }

  const client = options.stripeClient ?? (stripe() as unknown as StripeUsageClient);
  const quantity = Math.ceil(overageComputeHoursValue);
  const timestamp = Math.floor(now.getTime() / 1_000);
  await client.billing.meterEvents.create({
    event_name: VM_USAGE_METER_EVENT_NAME,
    payload: {
      stripe_customer_id: subscription.customerId,
      value: String(quantity),
    },
    identifier: usageEventIdentifier(subscription.id, period.start, timestamp, quantity),
    timestamp,
  });
  return {
    status: "reported",
    subscriptionId: subscription.id,
    billingTeamId,
    activeComputeHours,
    overageComputeHours: overageComputeHoursValue,
    quantity,
  };
}

/** Runs the usage reporter for active personal Pro subscription rows. */
export async function reportVmUsageForActiveSubscriptions(options: {
  readonly limit?: number;
  readonly concurrency?: number;
  readonly now?: Date;
  readonly enabled?: boolean;
  readonly stripeClient?: StripeUsageClient;
} = {}): Promise<VmUsageBatchReportResult> {
  const enabled = options.enabled ?? isStripeUsageReportingEnabled();
  if (!enabled) return { enabled: false, checked: 0, reported: 0, skipped: 0, failed: 0 };

  const limit = boundedInteger(options.limit ?? DEFAULT_REPORT_LIMIT, 1, DEFAULT_REPORT_LIMIT);
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
      customerId: stripeSubscriptions.customerId,
      stackUserId: stripeSubscriptions.stackUserId,
      stackTeamId: stripeSubscriptions.stackTeamId,
      scope: stripeSubscriptions.scope,
      plan: stripeSubscriptions.plan,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(and(
      inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      eq(stripeSubscriptions.scope, "user"),
      eq(stripeSubscriptions.plan, PRO_PLAN_ID),
    ))
    .limit(limit);

  let reported = 0;
  let skipped = 0;
  let failed = 0;
  await mapConcurrent(
    rows,
    boundedInteger(
      options.concurrency ?? DEFAULT_REPORT_CONCURRENCY,
      1,
      32,
    ),
    async (row) => {
      try {
        const result = await reportVmUsageForSubscription(row, {
          now: options.now,
          enabled,
          stripeClient: options.stripeClient,
        });
        if (result.status === "reported") reported += 1;
        else skipped += 1;
      } catch (error) {
        failed += 1;
        console.error("[billing] VM usage report failed", {
          subscriptionId: row.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    },
  );
  return { enabled, checked: rows.length, reported, skipped, failed };
}

function usageEventIdentifier(
  subscriptionId: string,
  periodStart: Date,
  timestamp: number,
  quantity: number,
): string {
  const periodStartSeconds = Math.floor(periodStart.getTime() / 1_000);
  const hourBucket = Math.floor(timestamp / 3_600);
  return `cmux-vm-usage:${subscriptionId}:${periodStartSeconds}:${hourBucket}:${quantity}`;
}

function roundHours(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function validDate(value: Date | null | undefined): value is Date {
  return value instanceof Date && Number.isFinite(value.getTime());
}

async function mapConcurrent<T>(
  values: readonly T[],
  concurrency: number,
  visit: (value: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, async () => {
      while (next < values.length) {
        const index = next;
        next += 1;
        await visit(values[index]!);
      }
    }),
  );
}

function boundedInteger(value: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) return minimum;
  return Math.max(minimum, Math.min(maximum, Math.floor(value)));
}
