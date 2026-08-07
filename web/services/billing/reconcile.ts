import * as Sentry from "@sentry/nextjs";
import { asc } from "drizzle-orm";
import type Stripe from "stripe";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureCoderouterError } from "../errors";
import { applySubscriptionUpdate } from "./purchase";
import { stripe } from "./stripe";

const DEFAULT_LIMIT = 1_000;
const DEFAULT_CONCURRENCY = 8;

type SubscriptionSnapshot = {
  readonly id: string;
  readonly status: string;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: Date | null;
};

export type BillingReconcileResult = {
  readonly checked: number;
  readonly drifted: number;
  readonly repaired: number;
  readonly failed: number;
  readonly truncated: boolean;
};

type BillingReconcileDependencies = {
  readonly list?: (limit: number) => Promise<readonly SubscriptionSnapshot[]>;
  readonly retrieve?: (id: string) => Promise<Stripe.Subscription>;
  readonly apply?: (subscription: Stripe.Subscription) => Promise<unknown>;
  readonly captureError?: (
    error: unknown,
    context: Record<string, string | number | boolean>,
  ) => void;
  readonly concurrency?: number;
};

/**
 * Repairs Stripe/RDS entitlement drift outside request traffic.
 *
 * Stripe remains authoritative. Re-applying a subscription is idempotent and
 * goes through the same per-principal advisory lock, Stack metadata update,
 * and route-token revocation path as a signed webhook. Retrievals fan out with
 * bounded concurrency; mutations retain their existing principal locks.
 */
export async function reconcileStripeSubscriptions(
  options: {
    readonly limit?: number;
    readonly dryRun?: boolean;
  } = {},
  dependencies: BillingReconcileDependencies = {},
): Promise<BillingReconcileResult> {
  const limit = clampInteger(options.limit ?? DEFAULT_LIMIT, 1, DEFAULT_LIMIT);
  const list = dependencies.list ?? listSubscriptionSnapshots;
  const retrieve = dependencies.retrieve ??
    ((id) => stripe().subscriptions.retrieve(id));
  const apply = dependencies.apply ?? ((subscription) =>
    applySubscriptionUpdate(subscription));
  const captureError = dependencies.captureError ?? captureCoderouterError;
  const rows = await list(limit + 1);
  const snapshots = rows.slice(0, limit);

  let drifted = 0;
  let repaired = 0;
  let failed = 0;
  await mapConcurrent(
    snapshots,
    dependencies.concurrency ?? DEFAULT_CONCURRENCY,
    async (snapshot) => {
      try {
        const remote = await retrieve(snapshot.id);
        if (!hasDrift(snapshot, remote)) return;
        drifted += 1;
        if (options.dryRun) return;
        const result = await apply(remote);
        if (isSkipped(result)) {
          throw new Error("Stripe subscription could not be mapped to a billing principal");
        }
        repaired += 1;
      } catch (error) {
        failed += 1;
        captureError(error, {
          operation: "stripe_subscription_reconcile",
          // Deliberately omit subscription/customer/principal identifiers.
          recoverable: true,
        });
      }
    },
  );

  const result = {
    checked: snapshots.length,
    drifted,
    repaired,
    failed,
    truncated: rows.length > limit,
  };
  Sentry.addBreadcrumb({
    category: "billing.reconcile",
    level: failed > 0 ? "warning" : "info",
    message: "Stripe subscription reconciliation completed",
    data: result,
  });
  return result;
}

async function listSubscriptionSnapshots(
  limit: number,
): Promise<readonly SubscriptionSnapshot[]> {
  return cloudDb()
    .select({
      id: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
    })
    .from(stripeSubscriptions)
    .orderBy(asc(stripeSubscriptions.updatedAt))
    .limit(limit);
}

function hasDrift(
  local: SubscriptionSnapshot,
  remote: Stripe.Subscription,
): boolean {
  return local.status !== remote.status ||
    local.cancelAtPeriodEnd !== remote.cancel_at_period_end ||
    epochSeconds(local.currentPeriodEnd) !==
      (remote.items.data[0]?.current_period_end ?? null);
}

function epochSeconds(value: Date | null): number | null {
  return value ? Math.floor(value.getTime() / 1_000) : null;
}

function isSkipped(result: unknown): boolean {
  return typeof result === "object" && result !== null && "skipped" in result;
}

async function mapConcurrent<T>(
  values: readonly T[],
  concurrency: number,
  visit: (value: T) => Promise<void>,
): Promise<void> {
  const bounded = clampInteger(concurrency, 1, 32);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(bounded, values.length) }, async () => {
      while (next < values.length) {
        const index = next;
        next += 1;
        await visit(values[index]!);
      }
    }),
  );
}

function clampInteger(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, Math.floor(value)));
}
