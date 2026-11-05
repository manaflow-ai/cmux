import * as Sentry from "@sentry/nextjs";
import { and, asc, eq, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureCoderouterError } from "../errors";
import {
  revokeRouteTokensForTeam,
  revokeRouteTokensForUser,
} from "../coderouter/repository";
import { applySubscriptionUpdate } from "./purchase";
import { STRIPE_CALL_TIMEOUT_MS, stripe } from "./stripe";
import { planItem } from "./subscriptionItems";

const DEFAULT_LIMIT = 1_000;
// Each worker can hold a pool connection inside `apply`; the pool is shared
// with request traffic on the same instance (CMUX_DB_POOL_MAX, default 5).
const DEFAULT_CONCURRENCY = 3;
// The cron function is killed at 60 s. Stop starting rows well before that so
// the run answers, and the rows left over lead the next run.
const DEFAULT_BUDGET_MS = 35_000;

type SubscriptionSnapshot = {
  readonly id: string;
  readonly status: string;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: Date | null;
  /** `last_reconciled_at` as read, so a claim can tell another run moved it. */
  readonly claimToken: string | null;
};

export type BillingReconcileResult = {
  readonly checked: number;
  readonly drifted: number;
  readonly repaired: number;
  readonly failed: number;
  /** Rows listed but not started because the time budget ran out. */
  readonly deferred: number;
  readonly truncated: boolean;
};

type BillingReconcileDependencies = {
  readonly list?: (limit: number) => Promise<readonly SubscriptionSnapshot[]>;
  readonly retrieve?: (id: string) => Promise<Stripe.Subscription>;
  readonly apply?: (subscription: Stripe.Subscription) => Promise<unknown>;
  /** Stamp the row checked unless another run already did; false skips it. */
  readonly claim?: (snapshot: SubscriptionSnapshot) => Promise<boolean>;
  readonly captureError?: (
    error: unknown,
    context: Record<string, string | number | boolean>,
  ) => void;
  readonly concurrency?: number;
  readonly budgetMs?: number;
  readonly now?: () => number;
};

/**
 * Repairs Stripe/RDS entitlement drift outside request traffic.
 *
 * Stripe remains authoritative. Re-applying a subscription is idempotent and
 * goes through the same per-principal advisory lock, Stack metadata update,
 * and route-token revocation path as a signed webhook. Retrievals fan out with
 * bounded concurrency; mutations retain their existing principal locks.
 *
 * No connection is held for the whole run. Each row is claimed with a
 * compare-and-set on `last_reconciled_at` just before it is checked, so
 * overlapping cron and operator runs split the rows instead of queueing on a
 * lock, and a run cut short keeps the progress it made.
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
    ((id) => stripe().subscriptions.retrieve(id, {}, { timeout: STRIPE_CALL_TIMEOUT_MS }));
  const apply = dependencies.apply ?? applySubscriptionUpdateAndRevokeRoutes;
  const claim = dependencies.claim ?? claimSubscriptionCheck;
  const captureError = dependencies.captureError ?? captureCoderouterError;
  const now = dependencies.now ?? Date.now;
  const deadline = now() + (dependencies.budgetMs ?? DEFAULT_BUDGET_MS);
  const rows = await list(limit + 1);
  const snapshots = rows.slice(0, limit);

  let checked = 0;
  let drifted = 0;
  let repaired = 0;
  let failed = 0;
  let deferred = 0;
  await mapConcurrent(
    snapshots,
    dependencies.concurrency ?? DEFAULT_CONCURRENCY,
    async (snapshot) => {
      if (now() >= deadline) {
        deferred += 1;
        return;
      }
      try {
        if (!options.dryRun && !(await claim(snapshot))) return;
        checked += 1;
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
    checked,
    drifted,
    repaired,
    failed,
    deferred,
    truncated: rows.length > limit || deferred > 0,
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

async function listSubscriptionSnapshots(
  limit: number,
): Promise<readonly SubscriptionSnapshot[]> {
  return cloudDb()
    .select({
      id: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      claimToken: sql<string | null>`${stripeSubscriptions.lastReconciledAt}::text`,
    })
    .from(stripeSubscriptions)
    .orderBy(
      sql`${stripeSubscriptions.lastReconciledAt} asc nulls first`,
      asc(stripeSubscriptions.id),
    )
    .limit(limit);
}

async function claimSubscriptionCheck(snapshot: SubscriptionSnapshot): Promise<boolean> {
  // Compared as text: a JS Date would drop the microseconds Postgres keeps.
  const claimed = await cloudDb()
    .update(stripeSubscriptions)
    .set({ lastReconciledAt: sql`now()` })
    .where(and(
      eq(stripeSubscriptions.id, snapshot.id),
      sql`${stripeSubscriptions.lastReconciledAt}::text is not distinct from ${snapshot.claimToken}`,
    ))
    .returning({ id: stripeSubscriptions.id });
  return claimed.length > 0;
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
