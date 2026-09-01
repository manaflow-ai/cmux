import * as Sentry from "@sentry/nextjs";
import { asc, eq, inArray, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { getStackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureBillingTeamSeatSync } from "../analytics/stripeBilling";
import { captureCoderouterError } from "../errors";
import {
  revokeRouteTokensForTeam,
  revokeRouteTokensForUser,
} from "../coderouter/repository";
import {
  applySubscriptionUpdate,
  isActiveStripeSubscriptionStatus,
} from "./purchase";
import { stripe } from "./stripe";

const DEFAULT_LIMIT = 1_000;
const DEFAULT_CONCURRENCY = 8;
const TEAM_SEAT_SYNC_LIMIT = 50;

type SubscriptionSnapshot = {
  readonly id: string;
  readonly status: string;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: Date | null;
  readonly scope?: string;
  readonly stackTeamId?: string | null;
  readonly seats?: number | null;
};

type ReconcileStackTeam = {
  readonly listUsers?: () => Promise<readonly unknown[]>;
};

type TeamSeatSyncInput = {
  readonly subscriptionId: string;
  readonly teamId: string;
  readonly oldQuantity: number;
  readonly newQuantity: number;
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
  readonly getTeam?: (teamId: string) => Promise<ReconcileStackTeam | null>;
  readonly updateSubscriptionQuantity?: (
    id: string,
    params: Stripe.SubscriptionUpdateParams,
  ) => Promise<unknown>;
  readonly updateSeats?: (subscriptionId: string, seats: number) => Promise<void>;
  readonly captureTeamSeatSync?: (input: TeamSeatSyncInput) => Promise<void>;
  readonly captureError?: (
    error: unknown,
    context: Record<string, string | number | boolean>,
  ) => void;
  readonly concurrency?: number;
  readonly withLease?: <T>(task: () => Promise<T>) => Promise<T>;
};

/**
 * Repairs Stripe/RDS entitlement drift outside request traffic and keeps
 * active Team quantities aligned with Stack membership.
 *
 * Stripe remains authoritative. Re-applying a subscription is idempotent and
 * goes through the same per-principal advisory lock, Stack metadata update,
 * and route-token revocation path as a signed webhook. Retrievals fan out with
 * bounded concurrency; mutations retain their existing principal locks. Team
 * membership reads are capped per run so a large roster cannot exhaust the
 * cron duration budget.
 */
export async function reconcileStripeSubscriptions(
  options: {
    readonly limit?: number;
    readonly dryRun?: boolean;
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
  const getTeam = dependencies.getTeam ?? getStackTeamForReconcile;
  const updateSubscriptionQuantity = dependencies.updateSubscriptionQuantity ??
    updateStripeSubscriptionQuantity;
  const updateSeats = dependencies.updateSeats ?? updateLocalSubscriptionSeats;
  const captureTeamSeatSync = dependencies.captureTeamSeatSync ?? captureBillingTeamSeatSync;
  const rows = await list(limit + 1);
  const snapshots = rows.slice(0, limit);

  let drifted = 0;
  let repaired = 0;
  let failed = 0;
  let reservedTeamSeatSyncs = 0;
  await mapConcurrent(
    snapshots,
    dependencies.concurrency ?? DEFAULT_CONCURRENCY,
    async (snapshot) => {
      // Reserve team slots before the first await. The list is ordered by the
      // shared reconciliation cursor, so this keeps the bounded Stack work
      // focused on the oldest eligible team rows even when retrievals finish
      // out of order.
      const teamSeatSyncReserved = isActiveTeamSnapshot(snapshot) &&
        reservedTeamSeatSyncs < TEAM_SEAT_SYNC_LIMIT;
      if (teamSeatSyncReserved) reservedTeamSeatSyncs += 1;

      let rowDrifted = false;
      let rowRepaired = false;
      try {
        const remote = await retrieve(snapshot.id);
        if (hasDrift(snapshot, remote)) {
          rowDrifted = true;
          if (!options.dryRun) {
            const result = await apply(remote);
            if (isSkipped(result)) {
              throw new Error("Stripe subscription could not be mapped to a billing principal");
            }
            rowRepaired = true;
          }
        }

        if (
          teamSeatSyncReserved &&
          isActiveStripeSubscriptionStatus(remote.status)
        ) {
          const seatSync = await reconcileTeamSeatQuantity(
            snapshot,
            remote,
            options.dryRun ?? false,
            getTeam,
            updateSubscriptionQuantity,
            updateSeats,
            captureTeamSeatSync,
          );
          rowDrifted ||= seatSync.drifted;
          rowRepaired ||= seatSync.repaired;
        }
      } catch (error) {
        failed += 1;
        captureError(error, {
          operation: "stripe_subscription_reconcile",
          // Deliberately omit subscription/customer/principal identifiers.
          recoverable: true,
        });
      }
      if (rowDrifted) drifted += 1;
      if (rowRepaired) repaired += 1;
    },
  );
  if (!options.dryRun && snapshots.length > 0) {
    await markChecked(snapshots.map((snapshot) => snapshot.id));
  }

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
      scope: stripeSubscriptions.scope,
      stackTeamId: stripeSubscriptions.stackTeamId,
      seats: stripeSubscriptions.seats,
    })
    .from(stripeSubscriptions)
    .orderBy(
      sql`${stripeSubscriptions.lastReconciledAt} asc nulls first`,
      asc(stripeSubscriptions.id),
    )
    .limit(limit);
}

function isActiveTeamSnapshot(snapshot: SubscriptionSnapshot): boolean {
  return snapshot.scope === "team" &&
    typeof snapshot.stackTeamId === "string" &&
    snapshot.stackTeamId.length > 0 &&
    isActiveStripeSubscriptionStatus(snapshot.status);
}

async function reconcileTeamSeatQuantity(
  snapshot: SubscriptionSnapshot,
  remote: Stripe.Subscription,
  dryRun: boolean,
  getTeam: (teamId: string) => Promise<ReconcileStackTeam | null>,
  updateSubscriptionQuantity: (
    id: string,
    params: Stripe.SubscriptionUpdateParams,
  ) => Promise<unknown>,
  updateSeats: (subscriptionId: string, seats: number) => Promise<void>,
  captureTeamSeatSync: (input: TeamSeatSyncInput) => Promise<void>,
): Promise<{ readonly drifted: boolean; readonly repaired: boolean }> {
  const teamId = snapshot.stackTeamId;
  if (!teamId) return { drifted: false, repaired: false };

  const team = await getTeam(teamId);
  if (!team) throw new Error(`Stack team not found for seat reconciliation: ${teamId}`);
  if (typeof team.listUsers !== "function") {
    throw new Error("Stack Auth server SDK cannot list team members");
  }
  const members = await team.listUsers();
  if (!Array.isArray(members)) {
    throw new Error("Stack team member listing returned an invalid result");
  }

  const desiredQuantity = Math.max(1, members.length);
  const stripeQuantity = finiteQuantity(remote.items?.data?.[0]?.quantity);
  const storedQuantity = finiteQuantity(snapshot.seats);
  const stripeNeedsUpdate = stripeQuantity !== desiredQuantity;
  const localNeedsUpdate = storedQuantity !== desiredQuantity;
  if (!stripeNeedsUpdate && !localNeedsUpdate) {
    return { drifted: false, repaired: false };
  }
  if (dryRun) return { drifted: true, repaired: false };

  const oldQuantity = stripeQuantity ?? storedQuantity ?? 1;
  if (stripeNeedsUpdate) {
    const item = remote.items?.data?.[0];
    if (!item?.id) {
      throw new Error("Stripe team subscription is missing a subscription item");
    }
    await updateSubscriptionQuantity(remote.id, {
      items: [{ id: item.id, quantity: desiredQuantity }],
      proration_behavior: "create_prorations",
    });
  }
  if (localNeedsUpdate) {
    await updateSeats(snapshot.id, desiredQuantity);
  }
  await captureTeamSeatSync({
    subscriptionId: snapshot.id,
    teamId,
    oldQuantity,
    newQuantity: desiredQuantity,
  });
  return { drifted: true, repaired: true };
}

async function getStackTeamForReconcile(
  teamId: string,
): Promise<ReconcileStackTeam | null> {
  return getStackServerApp().getTeam(teamId);
}

async function updateStripeSubscriptionQuantity(
  id: string,
  params: Stripe.SubscriptionUpdateParams,
): Promise<unknown> {
  return stripe().subscriptions.update(id, params);
}

async function updateLocalSubscriptionSeats(
  subscriptionId: string,
  seats: number,
): Promise<void> {
  await cloudDb()
    .update(stripeSubscriptions)
    .set({ seats, updatedAt: sql`now()` })
    .where(eq(stripeSubscriptions.id, subscriptionId));
}

function finiteQuantity(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
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
