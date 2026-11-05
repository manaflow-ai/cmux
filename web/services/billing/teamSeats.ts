import { and, desc, eq, inArray } from "drizzle-orm";
import type Stripe from "stripe";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureCoderouterError } from "../errors";
import { defaultTeamStackApp, withStackDeadline, type TeamStackApp } from "../teams/stack";
import { ACTIVE_STRIPE_PRO_STATUSES, MAX_PLAN_ID, PRO_PLAN_ID, TEAM_PLAN_ID } from "./pro";
import { applySubscriptionUpdate } from "./purchase";
import { STRIPE_CALL_TIMEOUT_MS, stripe } from "./stripe";
import { databaseTeamSeatQueue, TEAM_SEATS_BUSY, type TeamSeatQueue } from "./teamSeatQueue";
import { billingPlanIdFromMetadata } from "./teamResolution";
import { planItem } from "./subscriptionItems";

/**
 * Seat rules for a Team subscription. Every current member is a billed seat,
 * pending invitations cost nothing, and a subscription never drops below one
 * seat. Pro and Max personal teams have a member cap instead of a quantity
 * (services/teams/seats.ts) and free teams have no subscription; both are
 * skipped. A quantity edited in Stripe is not fought: the reconciler runs
 * only on membership facts, and then the member count wins.
 */
export type SeatDecision =
  | { readonly action: "skip"; readonly reason: "personal_plan" | "no_team_subscription" }
  | { readonly action: "noop"; readonly quantity: number }
  | { readonly action: "update"; readonly from: number | null; readonly to: number };

export function billableSeats(memberCount: number): number {
  return Math.max(1, memberCount);
}

export function seatDecision(input: {
  readonly planId: string | null;
  readonly hasTeamSubscription: boolean;
  readonly memberCount: number;
  readonly quantity: number | null;
}): SeatDecision {
  if (input.planId === PRO_PLAN_ID || input.planId === MAX_PLAN_ID) return { action: "skip", reason: "personal_plan" };
  if (!input.hasTeamSubscription) return { action: "skip", reason: "no_team_subscription" };
  const to = billableSeats(input.memberCount);
  if (input.quantity === to) return { action: "noop", quantity: to };
  return { action: "update", from: input.quantity, to };
}

export type ActiveTeamSubscriptionRow = {
  readonly id: string;
  readonly seats: number | null;
};

/** The two Stripe calls the reconciler makes, so tests pass a fake. */
export type TeamSeatStripeClient = {
  retrieve(subscriptionId: string): Promise<Stripe.Subscription>;
  updateQuantity(subscriptionId: string, itemId: string, quantity: number): Promise<Stripe.Subscription>;
};

export type TeamSeatReconcileDependencies = {
  readonly queue?: TeamSeatQueue;
  readonly stack?: TeamStackApp;
  readonly activeSubscription?: (stackTeamId: string) => Promise<ActiveTeamSubscriptionRow | null>;
  readonly stripe?: TeamSeatStripeClient;
  /** Mirrors the updated subscription into our rows and Stack `cmuxSeats`. */
  readonly apply?: (subscription: Stripe.Subscription) => Promise<unknown>;
  readonly captureError?: (error: unknown, context: Record<string, string | number | boolean>) => void;
  readonly now?: () => number;
};

export type TeamSeatReconcileResult = {
  readonly checked: number;
  readonly updated: number;
  readonly skipped: number;
  readonly failed: number;
  readonly busy: number;
  /** Dirty teams left for the next pass because the time budget ran out. */
  readonly deferred: number;
};

export type TeamSeatOutcomeKind = "updated" | "noop" | "skipped" | "failed" | "busy";

const DEFAULT_LIMIT = 200;
// The cron function is killed at 60 s; a team takes up to two 10 s Stack
// calls and two Stripe calls, so stop starting teams with room to finish one.
const DEFAULT_BUDGET_MS = 25_000;

/**
 * Bring every dirty team's Stripe quantity to its member count. Safe to run
 * from several workers at once: each team is taken under a try-lock, and a
 * failure keeps the team dirty for the next cron pass. A run stops starting
 * teams after its time budget, and the teams it leaves stay oldest-dirty.
 */
export async function reconcileTeamSeats(
  options: { readonly teamIds?: readonly string[]; readonly limit?: number; readonly budgetMs?: number } = {},
  dependencies: TeamSeatReconcileDependencies = {},
): Promise<TeamSeatReconcileResult> {
  const queue = dependencies.queue ?? databaseTeamSeatQueue;
  const now = dependencies.now ?? Date.now;
  const deadline = now() + (options.budgetMs ?? DEFAULT_BUDGET_MS);
  const rows = await queue.listDirty(options.limit ?? DEFAULT_LIMIT, options.teamIds);
  const result = { checked: 0, updated: 0, skipped: 0, failed: 0, busy: 0, deferred: 0 };
  for (const row of rows) {
    if (now() >= deadline) {
      result.deferred = rows.length - result.checked;
      break;
    }
    result.checked += 1;
    const kind = await reconcileTeam(row.stackTeamId, row.dirtyAt, queue, dependencies);
    if (kind === "updated") result.updated += 1;
    else if (kind === "skipped") result.skipped += 1;
    else if (kind === "failed") result.failed += 1;
    else if (kind === "busy") result.busy += 1;
  }
  return result;
}

/**
 * The outcome is written after the lock's transaction ends, so a team holds
 * one pool connection at a time; the pool is shared with request traffic.
 */
async function reconcileTeam(
  stackTeamId: string,
  dirtyAt: Date,
  queue: TeamSeatQueue,
  dependencies: TeamSeatReconcileDependencies,
): Promise<TeamSeatOutcomeKind> {
  try {
    // An unsubscribed team needs no Stack calls and no lock: nothing to bill.
    const subscription = await (dependencies.activeSubscription ?? activeTeamSubscriptionRow)(stackTeamId);
    const locked = subscription === null
      ? NO_SUBSCRIPTION
      : await queue.withTeamLock(stackTeamId, () => reconcileTeamUnlocked(stackTeamId, subscription, dependencies));
    if (locked === TEAM_SEATS_BUSY) return "busy";
    await queue.recordOutcome(stackTeamId, dirtyAt, locked.outcome);
    return locked.kind;
  } catch (error) {
    (dependencies.captureError ?? captureCoderouterError)(error, {
      operation: "team_seat_reconcile",
      stackTeamId,
      recoverable: true,
    });
    await queue
      .recordOutcome(stackTeamId, dirtyAt, { memberCount: null, stripeQuantity: null, error: errorText(error) })
      .catch(() => console.error("team seat outcome write failed", { stackTeamId }));
    return "failed";
  }
}

type Reconciled = {
  readonly kind: Exclude<TeamSeatOutcomeKind, "busy" | "failed">;
  readonly outcome: { memberCount: number | null; stripeQuantity: number | null; error: null };
};

const NO_SUBSCRIPTION: Reconciled = {
  kind: "skipped",
  outcome: { memberCount: null, stripeQuantity: null, error: null },
};

async function reconcileTeamUnlocked(
  stackTeamId: string,
  subscription: ActiveTeamSubscriptionRow,
  dependencies: TeamSeatReconcileDependencies,
): Promise<Reconciled> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const team = await withStackDeadline(() => stack.getTeam(stackTeamId));
  if (!team) return NO_SUBSCRIPTION;
  const members = await withStackDeadline(() => team.listUsers());
  const memberCount = members.length;
  const decision = seatDecision({
    planId: billingPlanIdFromMetadata(team.clientReadOnlyMetadata),
    hasTeamSubscription: true,
    memberCount,
    quantity: subscription.seats,
  });
  if (decision.action === "skip") return { kind: "skipped", outcome: { memberCount, stripeQuantity: null, error: null } };
  if (decision.action === "noop") return { kind: "noop", outcome: { memberCount, stripeQuantity: decision.quantity, error: null } };
  const quantity = await updateStripeQuantity(subscription.id, decision.to, dependencies);
  return { kind: quantity.changed ? "updated" : "noop", outcome: { memberCount, stripeQuantity: quantity.value, error: null } };
}

/**
 * Re-read the live subscription before writing: our row may lag a webhook,
 * and a subscription that lapsed since is left alone.
 */
async function updateStripeQuantity(
  subscriptionId: string,
  to: number,
  dependencies: TeamSeatReconcileDependencies,
): Promise<{ changed: boolean; value: number | null }> {
  const client = dependencies.stripe ?? defaultTeamSeatStripeClient();
  const live = await client.retrieve(subscriptionId);
  const item = planItem(live);
  const current = typeof item?.quantity === "number" ? item.quantity : null;
  if (!item || !(ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(live.status)) {
    return { changed: false, value: current };
  }
  if (current === to) return { changed: false, value: current };
  const updated = await client.updateQuantity(subscriptionId, item.id, to);
  await (dependencies.apply ?? applySubscriptionUpdate)(updated);
  return { changed: true, value: planItem(updated)?.quantity ?? to };
}

async function activeTeamSubscriptionRow(stackTeamId: string): Promise<ActiveTeamSubscriptionRow | null> {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id, seats: stripeSubscriptions.seats })
    .from(stripeSubscriptions)
    .where(and(
      eq(stripeSubscriptions.stackTeamId, stackTeamId),
      eq(stripeSubscriptions.scope, "team"),
      eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
      inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
    ))
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

function defaultTeamSeatStripeClient(): TeamSeatStripeClient {
  return {
    retrieve: (subscriptionId) =>
      stripe().subscriptions.retrieve(subscriptionId, {}, { timeout: STRIPE_CALL_TIMEOUT_MS }),
    updateQuantity: (subscriptionId, itemId, quantity) =>
      stripe().subscriptions.update(subscriptionId, {
        items: [{ id: itemId, quantity }],
        proration_behavior: "create_prorations",
      }, { timeout: STRIPE_CALL_TIMEOUT_MS }),
  };
}

function errorText(error: unknown): string {
  const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  return message.slice(0, 500);
}
