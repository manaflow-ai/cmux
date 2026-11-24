// cmux NEXT Cloud subscriptions: the Stack metadata mirror.
//
// A NEXT subscription is a user-scoped Stripe row whose `plan` is `next_pro`
// or `next_max`. While one is active the user's clientReadOnlyMetadata names
// it in `cmuxNextPlan`, and in `cmuxPlan` unless a classic subscription
// already holds that key (the classic mirror in pro.ts hands `cmuxPlan` back
// when the classic plan lapses). An operator grant in `cmuxVmPlan` is never
// touched here.

import { and, eq, inArray, isNull } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import type { AccountDeletionUserMutationLease } from "../account/deletionLock";
import {
  NEXT_PLAN_IDS,
  NEXT_PLAN_METADATA_KEY,
  higherNextPlanId,
  nextPlanId,
  nextPlanRank,
  type NextPlanId,
} from "./nextPlans";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  isPaidPlanId,
  type ProMetadataCustomer,
  type ProMetadataJson,
} from "./pro";

export type NextPlanBillingDb = Pick<ReturnType<typeof cloudDb>, "select">;

/** The best active NEXT subscription the user holds (max beats pro), or null. */
export async function activeNextPlanForUser(
  db: NextPlanBillingDb,
  stackUserId: string,
): Promise<NextPlanId | null> {
  const rows = await db
    .select({ plan: stripeSubscriptions.plan })
    .from(stripeSubscriptions)
    .where(activeNextRows(stackUserId))
    .limit(10);
  let best: NextPlanId | null = null;
  for (const row of rows) best = higherNextPlanId(best, nextPlanId(row.plan));
  return best;
}

/** The user's best active NEXT subscription with its Stripe ids (the one an upgrade switches), or null. */
export async function activeNextSubscriptionForUser(
  db: NextPlanBillingDb,
  stackUserId: string,
): Promise<{ plan: NextPlanId; id: string; customerId: string } | null> {
  const rows = await db
    .select({ plan: stripeSubscriptions.plan, id: stripeSubscriptions.id, customerId: stripeSubscriptions.customerId })
    .from(stripeSubscriptions)
    .where(activeNextRows(stackUserId))
    .limit(10);
  type Active = { plan: NextPlanId; id: string; customerId: string };
  const active = rows.flatMap((row): Active[] => {
    const plan = nextPlanId(row.plan);
    return plan ? [{ plan, id: row.id, customerId: row.customerId }] : [];
  });
  return active.reduce<Active | null>((best, row) => (best === null || nextPlanRank(row.plan) > nextPlanRank(best.plan) ? row : best), null);
}

function activeNextRows(stackUserId: string) {
  return and(
    eq(stripeSubscriptions.stackUserId, stackUserId),
    isNull(stripeSubscriptions.stackTeamId),
    eq(stripeSubscriptions.scope, "user"),
    inArray(stripeSubscriptions.plan, NEXT_PLAN_IDS),
    inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
  );
}

/**
 * The metadata after mirroring `activePlan`, or null when nothing changes.
 * A classic paid value in `cmuxPlan` is kept; a NEXT value there follows the
 * subscription.
 */
export function nextPlanMirrorMetadata(
  raw: unknown,
  activePlan: NextPlanId | null,
): Record<string, unknown> | null {
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  if (metadata.cmuxAccountDeleting === true) return null;
  const before = JSON.stringify([metadata[NEXT_PLAN_METADATA_KEY], metadata.cmuxPlan]);
  const current = typeof metadata.cmuxPlan === "string" ? metadata.cmuxPlan : null;
  if (activePlan) {
    metadata[NEXT_PLAN_METADATA_KEY] = activePlan;
    if (!isPaidPlanId(current)) metadata.cmuxPlan = activePlan;
  } else {
    delete metadata[NEXT_PLAN_METADATA_KEY];
    if (nextPlanId(current)) delete metadata.cmuxPlan;
  }
  const after = JSON.stringify([metadata[NEXT_PLAN_METADATA_KEY], metadata.cmuxPlan]);
  return before === after ? null : metadata;
}

/**
 * Writes the NEXT plan mirror under the caller's account-mutation lease.
 * Returns the metadata written, or null when nothing changed.
 */
export async function syncNextPlanMetadata(
  user: ProMetadataCustomer,
  activePlan: NextPlanId | null,
  lease: AccountDeletionUserMutationLease,
): Promise<Record<string, unknown> | null> {
  const metadata = nextPlanMirrorMetadata(user.clientReadOnlyMetadata, activePlan);
  if (!metadata) return null;
  await lease.refresh();
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
  return metadata;
}
