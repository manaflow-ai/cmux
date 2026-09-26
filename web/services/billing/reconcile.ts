import * as Sentry from "@sentry/nextjs";
import { asc, inArray, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { getStackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureBillingTeamSeatDrift } from "../analytics/stripeBilling";
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

type TeamSeatDriftInput = {
  readonly subscriptionId: string;
  readonly teamId: string;
  readonly memberCount: number;
  readonly stripeQuantity: number | null;
  readonly storedSeats: number | null;
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
  readonly captureTeamSeatDrift?: (input: TeamSeatDriftInput) => Promise<void>;
  readonly captureError?: (
    error: unknown,
    context: Record<string, string | number | boolean>,
  ) => void;
  readonly concurrency?: number;
  readonly withLease?: <T>(task: () => Promise<T>) => Promise<T>;
};

/**
 * Reconciles Stripe/RDS entitlement drift outside request traffic and reports
 * active Team seat drift without changing Stripe or stored seat quantities.
 *
 * Stripe remains authoritative. Re-applying a subscription is idempotent and
 * goes through the same per-principal advisory lock, Stack metadata update,
 * and route-token revocation path as a signed webhook. Retrievals fan out with
 * bounded concurrency. Team membership reads are bounded by the reconciliation
 * batch and a per-team deadline; seat drift itself is report-only.
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
  const captureTeamSeatDrift = dependencies.captureTeamSeatDrift ?? captureBillingTeamSeatDrift;
  const rows = await list(limit + 1);
  const snapshots = rows.slice(0, limit);

  let drifted = 0;
  let repaired = 0;
  let failed = 0;
  let stackDeadlineTrips = 0;
  await mapConcurrent(
    snapshots,
    dependencies.concurrency ?? DEFAULT_CONCURRENCY,
    async (snapshot) => {
      let rowDrifted = false;
      let rowRepaired = false;
      try {
        const remote = await retrieve(snapshot.id);

        // Observe team seat drift BEFORE any mutation. This orders the
        // fail-closed identity checks inside detectTeamSeatDrift ahead of
        // apply(remote), so a subscription whose Stripe metadata points at a
        // different team (or a non-team plan) never mutates entitlements; and
        // the observation compares the roster against a snapshot that apply
        // has not yet rewritten. Trade-off: a Stack deadline trip also defers
        // that row's status repair to the next cycle, which is the safe side.
        // The trip breaker keeps a Stack outage from stranding more than a
        // few un-cancellable requests per run.
        if (
          isTeamSnapshot(snapshot) &&
          isActiveStripeSubscriptionStatus(remote.status) &&
          stackDeadlineTrips < STACK_DEADLINE_TRIP_LIMIT
        ) {
          const seatDrift = await detectTeamSeatDrift(
            snapshot,
            remote,
            getTeam,
            captureTeamSeatDrift,
          );
          rowDrifted ||= seatDrift.drifted;
        }

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
      } catch (error) {
        if (error instanceof StackDeadlineError) stackDeadlineTrips += 1;
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

/**
 * A team snapshot is eligible for seat-drift detection when it carries a
 * usable Stack team identity. The remote status check at the call site gates
 * the roster read, so local status drift does not suppress an active remote
 * team's report.
 */
function isTeamSnapshot(snapshot: SubscriptionSnapshot): boolean {
  return snapshot.scope === "team" &&
    typeof snapshot.stackTeamId === "string" &&
    snapshot.stackTeamId.length > 0;
}

/**
 * Reads the current Stack roster and reports disagreement with both remote
 * Stripe quantity and stored seats. This path is intentionally report-only.
 */
/** The Stack interaction (team lookup + roster read) exceeded its budget. */
class StackDeadlineError extends Error {
  constructor(teamId: string) {
    super(`Stack team interaction exceeded the per-team deadline: ${teamId}`);
    this.name = "StackDeadlineError";
  }
}

const STACK_TEAM_DEADLINE_MS = 15_000;
const STACK_DEADLINE_TRIP_LIMIT = 3;

async function detectTeamSeatDrift(
  snapshot: SubscriptionSnapshot,
  remote: Stripe.Subscription,
  getTeam: (teamId: string) => Promise<ReconcileStackTeam | null>,
  captureTeamSeatDrift: (input: TeamSeatDriftInput) => Promise<void>,
): Promise<{ readonly drifted: boolean }> {
  const teamId = snapshot.stackTeamId;
  if (!teamId) return { drifted: false };

  // The database snapshot can be stale. When the remote subscription carries
  // its own identity metadata, it must agree with the snapshot; otherwise we
  // could bill one team for another team's membership. Fail closed.
  const remoteTeamId = typeof remote.metadata?.stackTeamId === "string"
    ? remote.metadata.stackTeamId
    : null;
  if (remoteTeamId && remoteTeamId !== teamId) {
    throw new Error(
      `Stripe subscription team metadata disagrees with the local row: remote=${remoteTeamId} local=${teamId}`,
    );
  }
  const remotePlan = typeof remote.metadata?.plan === "string" ? remote.metadata.plan : null;
  if (remotePlan && remotePlan !== "team") {
    throw new Error(`Stripe subscription plan metadata is not a team plan: ${remotePlan}`);
  }

  // One deadline covers the ENTIRE Stack interaction: the team lookup can
  // hang exactly like the roster read. Stack's SDK takes no AbortSignal, so
  // a timed-out request cannot be cancelled; the run-level breaker in the
  // caller caps how many such requests one invocation can strand, and the
  // frozen Vercel instance discards them when the cron returns.
  let stackTimer: ReturnType<typeof setTimeout> | undefined;
  const stackDeadline = new Promise<never>((_, reject) => {
    stackTimer = setTimeout(
      () => reject(new StackDeadlineError(teamId)),
      STACK_TEAM_DEADLINE_MS,
    );
  });
  let members: readonly unknown[];
  try {
    members = await Promise.race([
      (async () => {
        const team = await getTeam(teamId);
        if (!team) throw new Error(`Stack team not found for seat drift detection: ${teamId}`);
        if (typeof team.listUsers !== "function") {
          throw new Error("Stack Auth server SDK cannot list team members");
        }
        return await team.listUsers();
      })(),
      stackDeadline,
    ]);
  } finally {
    clearTimeout(stackTimer);
  }
  if (!Array.isArray(members)) {
    throw new Error("Stack team member listing returned an invalid result");
  }

  const desiredQuantity = Math.max(1, members.length);
  const stripeQuantity = finiteQuantity(remote.items?.data?.[0]?.quantity);
  const storedSeats = finiteQuantity(snapshot.seats);
  if (stripeQuantity === desiredQuantity && storedSeats === desiredQuantity) {
    return { drifted: false };
  }

  await captureTeamSeatDrift({
    subscriptionId: snapshot.id,
    teamId,
    memberCount: members.length,
    stripeQuantity,
    storedSeats,
  });
  return { drifted: true };
}

async function getStackTeamForReconcile(
  teamId: string,
): Promise<ReconcileStackTeam | null> {
  return getStackServerApp().getTeam(teamId);
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
