// Double billing: one cmux account paying for a personal plan through both
// Stripe and the App Store (docs/billing/ios-in-app-purchases.md, "Double
// billing"). Checkout refuses a Stripe personal plan to an App Store
// subscriber, the account-token route refuses an App Store purchase to a
// Stripe subscriber, and this module catches whatever still gets through
// (an open Checkout session completed after the App Store purchase, a stale
// paywall): it records an incident, alerts, and reports it to analytics. It
// never refunds or cancels; that is a support decision.

import { and, desc, eq, inArray, isNull, notInArray, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { appleSubscriptions, billingDoubleSubscriptionIncidents, stripeSubscriptions } from "../../db/schema";
import { captureServerEvent, type ServerEventInput } from "../analytics/serverEvents";
import { captureBillingError } from "../errors";
import { appleSubscriptionRowsForUser, type AppleEntitlementRow } from "./apple/entitlement";
import { ACTIVE_STRIPE_PRO_STATUSES, PERSONAL_PLAN_IDS, isPersonalPlanId } from "./pro";

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Apple retries a failed renewal for up to 60 days and recovers the
 * subscription (charging again) if a retry succeeds. Past that, a row still
 * in billing retry only means a missed EXPIRED notification, so it stops
 * counting; otherwise one lost notification would block Stripe forever.
 */
export const APPLE_BILLING_RETRY_WINDOW_MS = 60 * DAY_MS;

/** Apple statuses that are paid, or that Apple can still renew or recover. */
const APPLE_BILLABLE_STATUSES = ["active", "grace_period", "billing_retry"] as const;

export type DoubleBillingDetector =
  | "stripe_checkout"
  | "stripe_subscription_created"
  | "apple_transaction"
  | "daily_scan";

/**
 * Whether this App Store subscription is paid for now or can still charge
 * the user again: a Production row in `active`, `grace_period`, or
 * `billing_retry` that is inside its paid period or grace period, or whose
 * auto-renew is on (or unknown) within Apple's billing retry window after
 * expiry. Unlike `appleSubscriptionGrantsAccess` it ignores whether the row
 * grants a plan right now: a billing-retry row past its grace period grants
 * nothing, but Apple charges again the moment a retry succeeds.
 *
 * Sandbox rows never count. Sandbox purchases are free, so a Sandbox row
 * next to a Stripe subscription costs the user nothing.
 */
export function appleSubscriptionMayBill(row: AppleEntitlementRow, now: Date = new Date()): boolean {
  if (row.environment !== "Production") return false;
  if (!isPersonalPlanId(row.planId)) return false;
  if (!(APPLE_BILLABLE_STATUSES as readonly string[]).includes(row.status)) return false;
  const paidThrough = Math.max(row.expiresAt?.getTime() ?? 0, row.gracePeriodExpiresAt?.getTime() ?? 0);
  if (paidThrough > now.getTime()) return true;
  if (row.autoRenewEnabled === false) return false;
  // An auto-renewable subscription always has an expiry; a row without one
  // is malformed, and refusing Stripe is the side that cannot double charge.
  if (!row.expiresAt) return true;
  return now.getTime() - row.expiresAt.getTime() < APPLE_BILLING_RETRY_WINDOW_MS;
}

export type StripeRecurringSubscription = {
  readonly id: string;
  readonly plan: string;
  readonly status: string;
};

export type DoubleBillingIncidentWrite = {
  readonly userId: string;
  readonly stripeSubscriptionId: string;
  readonly stripePlanId: string;
  readonly stripeStatus: string;
  readonly appleOriginalTransactionId: string;
  readonly applePlanId: string;
  readonly appleStatus: string;
  readonly appleEnvironment: string;
  readonly appleAutoRenewEnabled: boolean | null;
  readonly detectedBy: DoubleBillingDetector;
  readonly detectedAt: Date;
};

export type DoubleBillingIncident = DoubleBillingIncidentWrite & {
  readonly id: string;
  readonly firstDetectedBy: DoubleBillingDetector | string;
  readonly firstDetectedAt: Date;
  readonly resolvedAt: Date | null;
};

export type DoubleBillingStore = {
  readonly appleSubscriptions: (userId: string) => Promise<AppleEntitlementRow[]>;
  /** Active personal Stripe subscriptions; Founder's Edition (a one-time purchase) excluded. */
  readonly stripeSubscriptions: (userId: string) => Promise<StripeRecurringSubscription[]>;
  /**
   * Upserts the incident for one (user, Stripe subscription, Apple
   * subscription) pair. `opened` is true for a new incident and for one that
   * had been resolved and is open again.
   */
  readonly recordIncident: (incident: DoubleBillingIncidentWrite) => Promise<{ readonly id: string; readonly opened: boolean }>;
  /** Users with a Production Apple row and an active personal Stripe row; the scan's candidates. */
  readonly usersWithBothSources: () => Promise<string[]>;
  /** Resolves open incidents except the given ids and users' incidents; returns how many. */
  readonly resolveIncidentsExcept: (input: {
    readonly keepIds: readonly string[];
    readonly keepUserIds: readonly string[];
    readonly now: Date;
  }) => Promise<number>;
  readonly listIncidents: (input: { readonly includeResolved: boolean; readonly limit: number }) => Promise<DoubleBillingIncident[]>;
};

export type DoubleBillingDependencies = {
  readonly store: DoubleBillingStore;
  readonly captureEvent: (input: ServerEventInput) => Promise<void>;
  /** Pages the billing on-call (error tracker, `subsystem: billing`). */
  readonly alert: (error: Error, context: Record<string, string | number | boolean | null>) => void;
  readonly now: () => Date;
};

export class DoubleBillingDetectedError extends Error {
  constructor(readonly incidentId: string) {
    super("A cmux account pays for a personal plan through both Stripe and the App Store");
    this.name = "DoubleBillingDetectedError";
  }
}

export type DoubleBillingIncidentResult = {
  readonly id: string;
  readonly opened: boolean;
  readonly incident: DoubleBillingIncidentWrite;
};

/**
 * Records an incident for every pair of an active personal Stripe
 * subscription and an App Store subscription that may bill. Each newly
 * opened incident is logged, alerted, and sent to analytics once
 * (`billing_double_subscription_detected`); a repeat detection only moves
 * `last_detected_at`. Throws on a storage failure; callers on a payment path
 * use `reportDoubleBillingForUser`, which never throws.
 */
export async function detectDoubleBillingForUser(
  userId: string,
  detectedBy: DoubleBillingDetector,
  deps: DoubleBillingDependencies = defaultDoubleBillingDependencies(),
): Promise<DoubleBillingIncidentResult[]> {
  const now = deps.now();
  const [appleRows, stripeRows] = await Promise.all([
    deps.store.appleSubscriptions(userId),
    deps.store.stripeSubscriptions(userId),
  ]);
  const billingApple = appleRows.filter((row) => appleSubscriptionMayBill(row, now));
  if (billingApple.length === 0 || stripeRows.length === 0) return [];
  const results: DoubleBillingIncidentResult[] = [];
  for (const stripeRow of stripeRows) {
    for (const appleRow of billingApple) {
      const incident: DoubleBillingIncidentWrite = {
        userId,
        stripeSubscriptionId: stripeRow.id,
        stripePlanId: stripeRow.plan,
        stripeStatus: stripeRow.status,
        appleOriginalTransactionId: appleRow.originalTransactionId,
        applePlanId: appleRow.planId,
        appleStatus: appleRow.status,
        appleEnvironment: appleRow.environment,
        appleAutoRenewEnabled: appleRow.autoRenewEnabled ?? null,
        detectedBy,
        detectedAt: now,
      };
      const recorded = await deps.store.recordIncident(incident);
      results.push({ ...recorded, incident });
      if (recorded.opened) await announceIncident(recorded.id, incident, deps);
    }
  }
  return results;
}

async function announceIncident(
  id: string,
  incident: DoubleBillingIncidentWrite,
  deps: DoubleBillingDependencies,
): Promise<void> {
  const context = {
    incidentId: id,
    stackUserId: incident.userId,
    stripeSubscriptionId: incident.stripeSubscriptionId,
    stripePlanId: incident.stripePlanId,
    stripeStatus: incident.stripeStatus,
    appleOriginalTransactionId: incident.appleOriginalTransactionId,
    applePlanId: incident.applePlanId,
    appleStatus: incident.appleStatus,
    detectedBy: incident.detectedBy,
  };
  console.error("billing: double subscription detected (Stripe and App Store)", context);
  try {
    deps.alert(new DoubleBillingDetectedError(id), context);
  } catch {
    // Alerting is best effort; the incident row is the durable record.
  }
  await deps.captureEvent({
    event: "billing_double_subscription_detected",
    distinctId: incident.userId,
    // One event per opening of an incident, even if two detectors race.
    insertId: `double_billing:${id}:${incident.detectedAt.toISOString().slice(0, 10)}`,
    timestamp: incident.detectedAt,
    properties: {
      incident_id: id,
      detected_by: incident.detectedBy,
      stripe_subscription_id: incident.stripeSubscriptionId,
      stripe_plan_id: incident.stripePlanId,
      stripe_status: incident.stripeStatus,
      apple_original_transaction_id: incident.appleOriginalTransactionId,
      apple_plan_id: incident.applePlanId,
      apple_status: incident.appleStatus,
      apple_environment: incident.appleEnvironment,
      apple_auto_renew_enabled: incident.appleAutoRenewEnabled,
    },
  }).catch(() => undefined);
}

/**
 * `detectDoubleBillingForUser` for payment paths (the Stripe webhook, the
 * App Store transaction and notification flows): a failure is logged and
 * reported, never thrown, so detection can never fail or retry a purchase.
 * The daily scan finds anything a failure here missed.
 */
export async function reportDoubleBillingForUser(
  userId: string,
  detectedBy: DoubleBillingDetector,
  deps?: DoubleBillingDependencies,
): Promise<void> {
  try {
    await detectDoubleBillingForUser(userId, detectedBy, deps ?? defaultDoubleBillingDependencies());
  } catch (error) {
    console.error("billing: double subscription check failed", {
      stackUserId: userId,
      detectedBy,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    captureBillingError(error, { operation: "double_billing_check", stackUserId: userId, detectedBy });
  }
}

export type DoubleBillingScanResult = {
  readonly users: number;
  readonly openIncidents: number;
  readonly newIncidents: number;
  readonly resolvedIncidents: number;
  readonly failedUsers: number;
};

/**
 * `GET /api/cron/billing-double-subscriptions` (daily). Checks every user
 * who has both a Production App Store row and an active personal Stripe
 * subscription, opens incidents for new pairs, and resolves open incidents
 * whose pair no longer bills twice. A user whose check failed keeps their
 * incidents open.
 */
export async function scanDoubleBilling(
  deps: DoubleBillingDependencies = defaultDoubleBillingDependencies(),
): Promise<DoubleBillingScanResult> {
  const now = deps.now();
  const users = await deps.store.usersWithBothSources();
  const keepIds: string[] = [];
  const failed: string[] = [];
  let newIncidents = 0;
  for (const userId of users) {
    try {
      const results = await detectDoubleBillingForUser(userId, "daily_scan", deps);
      for (const result of results) {
        keepIds.push(result.id);
        if (result.opened) newIncidents += 1;
      }
    } catch (error) {
      failed.push(userId);
      captureBillingError(error, { operation: "double_billing_scan", stackUserId: userId });
    }
  }
  const resolvedIncidents = await deps.store.resolveIncidentsExcept({ keepIds, keepUserIds: failed, now });
  const result = {
    users: users.length,
    openIncidents: keepIds.length,
    newIncidents,
    resolvedIncidents,
    failedUsers: failed.length,
  };
  console.info("billing: double subscription scan", result);
  await deps.captureEvent({
    event: "billing_double_subscription_scan",
    distinctId: "cmux-billing-cron",
    insertId: `double_billing_scan:${now.toISOString().slice(0, 10)}`,
    timestamp: now,
    properties: {
      users_checked: result.users,
      open_incidents: result.openIncidents,
      new_incidents: result.newIncidents,
      resolved_incidents: result.resolvedIncidents,
      failed_users: result.failedUsers,
    },
  }).catch(() => undefined);
  return result;
}

/**
 * The App Store subscription that must stop a Stripe personal checkout, or
 * null. See `appleSubscriptionMayBill`. A deployment without a database has
 * no App Store rows; any other read failure throws, so checkout fails closed.
 */
export async function appleSubscriptionBlockingStripeCheckout(
  userId: string,
  options: { readonly now?: Date; readonly rows?: (userId: string) => Promise<AppleEntitlementRow[]> } = {},
): Promise<AppleEntitlementRow | null> {
  const rows = await (options.rows ?? appleRowsOrEmpty)(userId);
  // Lightweight database doubles in older tests may return non-array values.
  if (!Array.isArray(rows)) return null;
  const now = options.now ?? new Date();
  return rows.find((row) => appleSubscriptionMayBill(row, now)) ?? null;
}

/**
 * For page personalization only (pricing, billing): whether to show "Manage
 * in the App Store" instead of checkout. A failed read answers false so the
 * page still renders; checkout itself re-checks and fails closed.
 */
export async function hasAppStoreSubscriptionThatMayBill(userId: string): Promise<boolean> {
  try {
    return (await appleSubscriptionBlockingStripeCheckout(userId)) !== null;
  } catch {
    return false;
  }
}

async function appleRowsOrEmpty(userId: string): Promise<AppleEntitlementRow[]> {
  try {
    return await appleSubscriptionRowsForUser(userId);
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) return [];
    throw error;
  }
}

function isFounderRow(row: { readonly id: string; readonly foundersEdition: string | null }): boolean {
  return row.id.startsWith("founders_") || row.foundersEdition === "true";
}

const incidentColumns = {
  id: billingDoubleSubscriptionIncidents.id,
  userId: billingDoubleSubscriptionIncidents.userId,
  stripeSubscriptionId: billingDoubleSubscriptionIncidents.stripeSubscriptionId,
  stripePlanId: billingDoubleSubscriptionIncidents.stripePlanId,
  stripeStatus: billingDoubleSubscriptionIncidents.stripeStatus,
  appleOriginalTransactionId: billingDoubleSubscriptionIncidents.appleOriginalTransactionId,
  applePlanId: billingDoubleSubscriptionIncidents.applePlanId,
  appleStatus: billingDoubleSubscriptionIncidents.appleStatus,
  appleEnvironment: billingDoubleSubscriptionIncidents.appleEnvironment,
  appleAutoRenewEnabled: billingDoubleSubscriptionIncidents.appleAutoRenewEnabled,
  firstDetectedBy: billingDoubleSubscriptionIncidents.firstDetectedBy,
  detectedBy: billingDoubleSubscriptionIncidents.lastDetectedBy,
  firstDetectedAt: billingDoubleSubscriptionIncidents.firstDetectedAt,
  detectedAt: billingDoubleSubscriptionIncidents.lastDetectedAt,
  resolvedAt: billingDoubleSubscriptionIncidents.resolvedAt,
};

export function databaseDoubleBillingStore(db: () => ReturnType<typeof cloudDb> = cloudDb): DoubleBillingStore {
  return {
    appleSubscriptions: appleRowsOrEmpty,
    stripeSubscriptions: async (userId) => {
      const rows = await db()
        .select({
          id: stripeSubscriptions.id,
          plan: stripeSubscriptions.plan,
          status: stripeSubscriptions.status,
          foundersEdition: sql<string | null>`${stripeSubscriptions.raw}->'metadata'->>'founders_edition'`,
        })
        .from(stripeSubscriptions)
        .where(and(
          eq(stripeSubscriptions.stackUserId, userId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        ));
      return rows.filter((row) => !isFounderRow(row)).map(({ id, plan, status }) => ({ id, plan, status }));
    },
    recordIncident: async (incident) => await db().transaction(async (tx) => {
      const key = `double-billing:${incident.userId}:${incident.stripeSubscriptionId}:${incident.appleOriginalTransactionId}`;
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`);
      const where = and(
        eq(billingDoubleSubscriptionIncidents.userId, incident.userId),
        eq(billingDoubleSubscriptionIncidents.stripeSubscriptionId, incident.stripeSubscriptionId),
        eq(billingDoubleSubscriptionIncidents.appleOriginalTransactionId, incident.appleOriginalTransactionId),
      );
      const state = {
        stripePlanId: incident.stripePlanId,
        stripeStatus: incident.stripeStatus,
        applePlanId: incident.applePlanId,
        appleStatus: incident.appleStatus,
        appleEnvironment: incident.appleEnvironment,
        appleAutoRenewEnabled: incident.appleAutoRenewEnabled,
        lastDetectedBy: incident.detectedBy,
        lastDetectedAt: incident.detectedAt,
      };
      const [existing] = await tx
        .select({ id: billingDoubleSubscriptionIncidents.id, resolvedAt: billingDoubleSubscriptionIncidents.resolvedAt })
        .from(billingDoubleSubscriptionIncidents)
        .where(where)
        .limit(1);
      if (!existing) {
        const [inserted] = await tx.insert(billingDoubleSubscriptionIncidents).values({
          userId: incident.userId,
          stripeSubscriptionId: incident.stripeSubscriptionId,
          appleOriginalTransactionId: incident.appleOriginalTransactionId,
          firstDetectedBy: incident.detectedBy,
          firstDetectedAt: incident.detectedAt,
          ...state,
        }).returning({ id: billingDoubleSubscriptionIncidents.id });
        if (!inserted) throw new Error("Double billing incident insert returned no row");
        return { id: inserted.id, opened: true };
      }
      await tx.update(billingDoubleSubscriptionIncidents)
        .set({ ...state, resolvedAt: null })
        .where(eq(billingDoubleSubscriptionIncidents.id, existing.id));
      return { id: existing.id, opened: existing.resolvedAt !== null };
    }),
    usersWithBothSources: async () => {
      const rows = await db()
        .selectDistinct({ userId: appleSubscriptions.userId })
        .from(appleSubscriptions)
        .innerJoin(stripeSubscriptions, and(
          eq(stripeSubscriptions.stackUserId, appleSubscriptions.userId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        ))
        .where(and(
          eq(appleSubscriptions.environment, "Production"),
          inArray(appleSubscriptions.status, APPLE_BILLABLE_STATUSES),
        ));
      return rows.map((row) => row.userId);
    },
    resolveIncidentsExcept: async ({ keepIds, keepUserIds, now }) => {
      const conditions = [isNull(billingDoubleSubscriptionIncidents.resolvedAt)];
      if (keepIds.length > 0) conditions.push(notInArray(billingDoubleSubscriptionIncidents.id, [...keepIds]));
      if (keepUserIds.length > 0) conditions.push(notInArray(billingDoubleSubscriptionIncidents.userId, [...keepUserIds]));
      const resolved = await db()
        .update(billingDoubleSubscriptionIncidents)
        .set({ resolvedAt: now })
        .where(and(...conditions))
        .returning({ id: billingDoubleSubscriptionIncidents.id });
      return resolved.length;
    },
    listIncidents: async ({ includeResolved, limit }) => {
      const query = db().select(incidentColumns).from(billingDoubleSubscriptionIncidents);
      const filtered = includeResolved ? query : query.where(isNull(billingDoubleSubscriptionIncidents.resolvedAt));
      const rows = await filtered.orderBy(desc(billingDoubleSubscriptionIncidents.lastDetectedAt)).limit(limit);
      return rows.map((row) => ({ ...row, detectedBy: row.detectedBy as DoubleBillingDetector }));
    },
  };
}

let defaultDependencies: DoubleBillingDependencies | null = null;

export function defaultDoubleBillingDependencies(): DoubleBillingDependencies {
  defaultDependencies ??= {
    store: databaseDoubleBillingStore(),
    captureEvent: (input) => captureServerEvent(input),
    alert: (error, context) => captureBillingError(error, context),
    now: () => new Date(),
  };
  return defaultDependencies;
}
