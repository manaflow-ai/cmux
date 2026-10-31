import * as Sentry from "@sentry/nextjs";
import { asc, inArray, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureCoderouterError } from "../errors";
import {
  revokeRouteTokensForTeam,
  revokeRouteTokensForUser,
} from "../coderouter/repository";
import { applySubscriptionUpdate } from "./purchase";
import { stripe } from "./stripe";
import { planItem } from "./subscriptionItems";

const DEFAULT_LIMIT = 1_000;
const DEFAULT_CONCURRENCY = 8;
/**
 * Wall-clock budget for starting new Stripe checks. The cron route has a
 * 300 s function limit; stopping new work well before it lets the run mark
 * what it checked, so the next run starts on the rows this one never reached
 * instead of timing out on the same oldest rows forever.
 */
export const BILLING_RECONCILE_BUDGET_MS = 180_000;

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
  readonly markChecked?: (ids: readonly string[]) => Promise<void>;
  readonly captureError?: (
    error: unknown,
    context: Record<string, string | number | boolean>,
  ) => void;
  readonly concurrency?: number;
  /** Injected clock for the run budget. */
  readonly now?: () => number;
  readonly withLease?: <T>(task: () => Promise<T>) => Promise<T>;
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
    readonly budgetMs?: number;
  } = {},
  dependencies: BillingReconcileDependencies = {},
): Promise<BillingReconcileResult> {
  const withLease = dependencies.withLease ?? withReconciliationLease;
  return withLease(() => reconcileStripeSubscriptionsLocked(options, dependencies));
}

async function reconcileStripeSubscriptionsLocked(
  options: {
    readonly limit?: number;
    readonly dryRun?: boolean;
    readonly budgetMs?: number;
  },
  dependencies: BillingReconcileDependencies,
): Promise<BillingReconcileResult> {
  const limit = clampInteger(options.limit ?? DEFAULT_LIMIT, 1, DEFAULT_LIMIT);
  const list = dependencies.list ?? listSubscriptionSnapshots;
  const retrieve = dependencies.retrieve ??
    ((id) => stripe().subscriptions.retrieve(id));
  const apply = dependencies.apply ?? applySubscriptionUpdateAndRevokeRoutes;
  const markChecked = dependencies.markChecked ?? markSubscriptionsChecked;
  const captureError = dependencies.captureError ?? captureCoderouterError;
  const now = dependencies.now ?? Date.now;
  const deadline = now() + (options.budgetMs ?? BILLING_RECONCILE_BUDGET_MS);
  const rows = await list(limit + 1);
  const snapshots = rows.slice(0, limit);
  const visited: string[] = [];

  let drifted = 0;
  let repaired = 0;
  let failed = 0;
  await mapConcurrent(
    snapshots,
    dependencies.concurrency ?? DEFAULT_CONCURRENCY,
    () => now() < deadline,
    async (snapshot) => {
      visited.push(snapshot.id);
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
  if (!options.dryRun && visited.length > 0) {
    await markChecked(visited);
  }

  const result = {
    checked: visited.length,
    drifted,
    repaired,
    failed,
    truncated: rows.length > limit || visited.length < snapshots.length,
  };
  Sentry.addBreadcrumb({
    category: "billing.reconcile",
    level: failed > 0 ? "warning" : "info",
    message: "Stripe subscription reconciliation completed",
    data: result,
  });
  return result;
}

async function applySubscriptionUpdateAndRevokeRoutes(
  subscription: Stripe.Subscription,
) {
  const result = await applySubscriptionUpdate(subscription);
  if (!("skipped" in result) && !result.isActive) {
    if (result.scope === "user") {
      await revokeRouteTokensForUser(result.stackUserId);
    } else {
      await revokeRouteTokensForTeam(result.stackTeamId);
    }
  }
  return result;
}

async function withReconciliationLease<T>(
  task: () => Promise<T>,
): Promise<T> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${"coderouter:billing-reconcile"}, 0))`,
    );
    return task();
  });
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
    .orderBy(
      sql`${stripeSubscriptions.lastReconciledAt} asc nulls first`,
      asc(stripeSubscriptions.id),
    )
    .limit(limit);
}

async function markSubscriptionsChecked(ids: readonly string[]): Promise<void> {
  if (ids.length === 0) return;
  await cloudDb()
    .update(stripeSubscriptions)
    .set({ lastReconciledAt: sql`now()` })
    .where(inArray(stripeSubscriptions.id, [...ids]));
}

function hasDrift(
  local: SubscriptionSnapshot,
  remote: Stripe.Subscription,
): boolean {
  return local.status !== remote.status ||
    local.cancelAtPeriodEnd !== remote.cancel_at_period_end ||
    epochSeconds(local.currentPeriodEnd) !==
      (planItem(remote)?.current_period_end ?? null);
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
  canStart: () => boolean,
  visit: (value: T) => Promise<void>,
): Promise<void> {
  const bounded = clampInteger(concurrency, 1, 32);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(bounded, values.length) }, async () => {
      while (next < values.length && canStart()) {
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
