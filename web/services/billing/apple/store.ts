// Postgres persistence for iOS in-app purchases. Every write is idempotent:
// account tokens are minted once per user, transactions and notifications
// are keyed by Apple's ids, and subscription state only moves forward in
// Apple `signedDate` order and never back to an older transaction. Ownership follows the newest transaction's
// `appAccountToken` (planAppleSubscriptionWrite).

import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray, isNull, lt, max, or, sql, type SQL } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import {
  appleAccountTokens,
  appleNotificationHistoryCursors,
  appleNotifications,
  appleSubscriptions,
  appleTransactions,
} from "../../../db/schema";
import type { AppleSubscriptionState, AppleTransactionRow } from "./state";

type Db = ReturnType<typeof cloudDb>;

export type AppleSubscriptionRow = typeof appleSubscriptions.$inferSelect;
export type AppleNotificationRow = typeof appleNotifications.$inferSelect;
export type AppleNotificationHistoryCursor = Omit<typeof appleNotificationHistoryCursors.$inferSelect, "updatedAt">;

export class AppleOwnershipError extends Error {
  constructor(readonly originalTransactionId: string) {
    super("Apple subscription belongs to another cmux account");
    this.name = "AppleOwnershipError";
  }
}

export type AppleSubscriptionWrite = {
  /** False when the stored state is newer (an out-of-order delivery). */
  readonly applied: boolean;
  readonly previous: AppleSubscriptionRow | null;
  readonly current: AppleSubscriptionRow;
  /** The previous owner when this write moved the subscription to another user. */
  readonly transferredFrom: string | null;
};

/** Who may own the subscription a state write describes. */
export type AppleSubscriptionClaim = {
  /**
   * The cmux user the state's `appAccountToken` maps to, or null for a
   * token-less transaction or a token cmux never minted.
   */
  readonly tokenOwner: string | null;
  /**
   * The signed-in user posting a client transaction. The write fails with
   * AppleOwnershipError unless the subscription ends up owned by this user.
   */
  readonly caller?: string;
};

type OwnedSubscription = Pick<
  AppleSubscriptionRow,
  "originalTransactionId" | "userId" | "lastTransactionId" | "purchaseDate" | "stateSignedAt"
>;

export type AppleSubscriptionWritePlan =
  | { readonly kind: "write"; readonly userId: string; readonly transferredFrom: string | null }
  | { readonly kind: "stale" };

/** A different transaction purchased after the stored one: an upgrade, resubscribe, or renewal. */
function isNewerTransaction(state: AppleSubscriptionState, previous: OwnedSubscription): boolean {
  if (state.lastTransactionId === previous.lastTransactionId || !state.purchaseDate) return false;
  return !previous.purchaseDate || state.purchaseDate.getTime() > previous.purchaseDate.getTime();
}

/**
 * A different transaction purchased before the stored one, such as a refund
 * or refund decision about last month's renewal. It describes history, not
 * the subscription's current period.
 */
export function isOlderAppleTransaction(
  state: Pick<AppleSubscriptionState, "lastTransactionId" | "purchaseDate">,
  previous: Pick<AppleSubscriptionRow, "lastTransactionId" | "purchaseDate">,
): boolean {
  if (state.lastTransactionId === previous.lastTransactionId || !state.purchaseDate || !previous.purchaseDate) {
    return false;
  }
  return state.purchaseDate.getTime() < previous.purchaseDate.getTime();
}

/**
 * Decides one subscription write under the per-subscription lock. Both stores
 * share it so the in-memory test store keeps the database contract.
 *
 * The `appAccountToken` on the newest transaction is authoritative: when the
 * same Apple ID buys again (upgrade or resubscribe) from another cmux
 * account, the subscription moves to that account. A token-less transaction,
 * an unknown token, or an older transaction never moves it.
 */
export function planAppleSubscriptionWrite(
  previous: OwnedSubscription | null,
  state: AppleSubscriptionState,
  claim: AppleSubscriptionClaim,
): AppleSubscriptionWritePlan {
  if (!previous) {
    const owner = claim.tokenOwner ?? claim.caller ?? null;
    if (!owner || (claim.caller !== undefined && owner !== claim.caller)) {
      throw new AppleOwnershipError(state.originalTransactionId);
    }
    return { kind: "write", userId: owner, transferredFrom: null };
  }
  // The row describes the latest transaction: an older signed date or an
  // older transaction (a refund of a past period) leaves it alone.
  const fresh = previous.stateSignedAt.getTime() <= state.stateSignedAt.getTime() &&
    !isOlderAppleTransaction(state, previous);
  const moves = fresh &&
    claim.tokenOwner !== null &&
    claim.tokenOwner !== previous.userId &&
    isNewerTransaction(state, previous);
  const owner = moves ? claim.tokenOwner! : previous.userId;
  if (claim.caller !== undefined && owner !== claim.caller) {
    throw new AppleOwnershipError(state.originalTransactionId);
  }
  if (!fresh) return { kind: "stale" };
  return { kind: "write", userId: owner, transferredFrom: moves ? previous.userId : null };
}

export type AppleLapsedSubscription = Pick<
  AppleSubscriptionRow,
  | "originalTransactionId"
  | "userId"
  | "bundleId"
  | "environment"
  | "expiresAt"
  | "gracePeriodExpiresAt"
  | "appleCheckedAt"
>;

/** Failed applications before a notification is dead-lettered (about 3 days of retries). */
export const APPLE_NOTIFICATION_MAX_ATTEMPTS = 12;
const RETRY_BASE_SECONDS = 300;
const RETRY_MAX_SECONDS = 12 * 60 * 60;

/**
 * Delay before the next retry once `attemptCount` applications have failed:
 * 5 minutes, doubling, at most 12 hours. The database store computes the
 * same value in SQL.
 */
export function appleNotificationRetryDelayMs(attemptCount: number): number {
  const exponent = Math.max(0, attemptCount - 1);
  return Math.min(RETRY_BASE_SECONDS * 2 ** exponent, RETRY_MAX_SECONDS) * 1000;
}

export type AppleNotificationFailure = {
  readonly attemptCount: number;
  readonly deadLettered: boolean;
};

/** Rows the renewal re-check asks Apple about (see `renewalCheckCandidates`). */
export type AppleRenewalCheckQuery = {
  /** Access must end after this... */
  readonly accessEndsAfter: Date;
  /** ...and no later than this. */
  readonly accessEndsBy: Date;
  /** Skip rows Apple answered for at or after this time. */
  readonly checkedBefore: Date;
  readonly limit: number;
};

/** Statuses that can grant access; their rows are what the lapse sweep watches. */
export const APPLE_GRANTING_STATUSES = ["active", "grace_period", "billing_retry"] as const;

/** When access ends: the later of expiry and grace end (null when neither is set). */
export function appleAccessEndsAt(row: Pick<AppleSubscriptionRow, "expiresAt" | "gracePeriodExpiresAt">): Date | null {
  const times = [row.expiresAt, row.gracePeriodExpiresAt]
    .filter((value): value is Date => value !== null)
    .map((value) => value.getTime());
  return times.length > 0 ? new Date(Math.max(...times)) : null;
}

/** The status a row moves to once the sweep applied its lapse. */
export function appleSweptStatus(status: string): AppleSubscriptionRow["status"] {
  if (status === "active") return "expired";
  if (status === "grace_period") return "billing_retry";
  return status as AppleSubscriptionRow["status"];
}

export type AppleNotificationInsert = {
  readonly notificationUuid: string;
  readonly notificationType: string;
  readonly subtype: string | null;
  readonly environment: string;
  readonly originalTransactionId: string | null;
  readonly signedDate: Date;
  readonly payload: Record<string, unknown>;
};

export type AppleIapStore = {
  accountTokenForUser(userId: string): Promise<string>;
  userIdForAccountToken(token: string): Promise<string | null>;
  subscription(originalTransactionId: string): Promise<AppleSubscriptionRow | null>;
  writeSubscriptionState(state: AppleSubscriptionState, claim: AppleSubscriptionClaim): Promise<AppleSubscriptionWrite>;
  recordTransaction(row: AppleTransactionRow): Promise<void>;
  /** Inserts the ledger row; false when the notification UUID already exists. */
  insertNotification(row: AppleNotificationInsert): Promise<{ inserted: boolean; row: AppleNotificationRow }>;
  notification(notificationUuid: string): Promise<AppleNotificationRow | null>;
  markNotificationProcessed(notificationUuid: string, processedAt: Date): Promise<void>;
  /**
   * Records a failed application: counts the attempt, schedules the next one
   * (`appleNotificationRetryDelayMs`), and dead-letters the row once
   * APPLE_NOTIFICATION_MAX_ATTEMPTS attempts failed.
   */
  markNotificationFailed(notificationUuid: string, error: string, now: Date): Promise<AppleNotificationFailure>;
  /** Closes a notification that can never apply, keeping the reason. */
  markNotificationSkipped(notificationUuid: string, reason: string, processedAt: Date): Promise<void>;
  /**
   * Ledger rows still owed an entitlement application (failed or never run)
   * that are due (`next_attempt_at` null or past) and not dead-lettered,
   * earliest due first.
   */
  pendingNotifications(limit: number, now: Date): Promise<AppleNotificationRow[]>;
  /**
   * Rows still in an access-granting status whose access ended (the later of
   * `expires_at` and `grace_period_expires_at`) before `endedBefore` and
   * after their last write, oldest lapse first. The sweep passes a cutoff an
   * hour before now, so a late renewal has time to arrive.
   */
  lapsedSubscriptions(endedBefore: Date, limit: number): Promise<AppleLapsedSubscription[]>;
  /**
   * `active` and `grace_period` rows with auto-renew on (or unknown) whose
   * access ends inside the query's window and that Apple has not answered for
   * since `checkedBefore`, soonest end first.
   */
  renewalCheckCandidates(query: AppleRenewalCheckQuery): Promise<AppleSubscriptionRow[]>;
  /** Records that Apple answered a status lookup for the subscription. Leaves `updated_at` alone. */
  markAppleChecked(originalTransactionId: string, checkedAt: Date): Promise<void>;
  notificationHistoryCursor(bundleId: string, environment: string): Promise<AppleNotificationHistoryCursor | null>;
  saveNotificationHistoryCursor(cursor: AppleNotificationHistoryCursor): Promise<void>;
  /** The newest `signed_date` in the ledger for the environment, or null. */
  latestNotificationSignedDate(environment: string): Promise<Date | null>;
  /**
   * Records that a lapse was applied, so the row does not match again:
   * `active` becomes `expired`, `grace_period` becomes `billing_retry` (Apple
   * may still recover it), and `updated_at` moves past the lapse. A row
   * written since it was listed is left alone.
   */
  markLapseSwept(originalTransactionIds: readonly string[], now: Date): Promise<void>;
};

/** `greatest` skips nulls, so a row with neither date never lapses. */
const ACCESS_ENDS_AT = sql`greatest(${appleSubscriptions.expiresAt}, ${appleSubscriptions.gracePeriodExpiresAt})`;

/** Access ended before `now` and the row was not written (or swept) since. */
function lapsedSince(now: Date) {
  return and(
    sql`${ACCESS_ENDS_AT} < ${now.toISOString()}::timestamptz`,
    lt(appleSubscriptions.updatedAt, ACCESS_ENDS_AT),
  );
}

function isUniqueViolation(error: unknown): boolean {
  const code = (error as { code?: unknown; cause?: { code?: unknown } } | null)?.code ??
    (error as { cause?: { code?: unknown } } | null)?.cause?.code;
  return code === "23505";
}

async function accountTokenForUser(db: Db, userId: string): Promise<string> {
  const existing = await db
    .select({ token: appleAccountTokens.appAccountToken })
    .from(appleAccountTokens)
    .where(eq(appleAccountTokens.userId, userId))
    .limit(1);
  if (existing[0]) return existing[0].token;
  try {
    await db.insert(appleAccountTokens)
      .values({ userId, appAccountToken: randomUUID() })
      .onConflictDoNothing({ target: appleAccountTokens.userId });
  } catch (error) {
    // A random UUID collision is astronomically unlikely; retry once anyway.
    if (!isUniqueViolation(error)) throw error;
    await db.insert(appleAccountTokens)
      .values({ userId, appAccountToken: randomUUID() })
      .onConflictDoNothing({ target: appleAccountTokens.userId });
  }
  const [row] = await db
    .select({ token: appleAccountTokens.appAccountToken })
    .from(appleAccountTokens)
    .where(eq(appleAccountTokens.userId, userId))
    .limit(1);
  if (!row) throw new Error("Apple account token was not persisted");
  return row.token;
}

function subscriptionValues(state: AppleSubscriptionState, userId: string, now: Date) {
  return {
    originalTransactionId: state.originalTransactionId,
    userId,
    appAccountToken: state.appAccountToken,
    bundleId: state.bundleId,
    environment: state.environment,
    productId: state.productId,
    planId: state.planId,
    status: state.status,
    autoRenewEnabled: state.autoRenewEnabled,
    autoRenewProductId: state.autoRenewProductId,
    purchaseDate: state.purchaseDate,
    originalPurchaseDate: state.originalPurchaseDate,
    expiresAt: state.expiresAt,
    gracePeriodExpiresAt: state.gracePeriodExpiresAt,
    storefront: state.storefront,
    currency: state.currency,
    priceMilliunits: state.priceMilliunits,
    lastTransactionId: state.lastTransactionId,
    revokedAt: state.revokedAt,
    revocationReason: state.revocationReason,
    stateSignedAt: state.stateSignedAt,
    updatedAt: now,
  };
}

async function writeSubscriptionState(
  db: Db,
  state: AppleSubscriptionState,
  claim: AppleSubscriptionClaim,
): Promise<AppleSubscriptionWrite> {
  return await db.transaction(async (tx) => {
    // Serialize writers of one subscription, including the first insert.
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${`apple-subscription:${state.originalTransactionId}`}, 0))`,
    );
    const [previous] = await tx
      .select()
      .from(appleSubscriptions)
      .where(eq(appleSubscriptions.originalTransactionId, state.originalTransactionId))
      .limit(1);
    const plan = planAppleSubscriptionWrite(previous ?? null, state, claim);
    if (plan.kind === "stale") return { applied: false, previous: previous!, current: previous!, transferredFrom: null };
    const values = subscriptionValues(state, plan.userId, new Date());
    const [current] = previous
      ? await tx.update(appleSubscriptions)
        .set(values)
        .where(eq(appleSubscriptions.originalTransactionId, state.originalTransactionId))
        .returning()
      : await tx.insert(appleSubscriptions).values(values).returning();
    if (!current) throw new Error("Apple subscription write returned no row");
    return { applied: true, previous: previous ?? null, current, transferredFrom: plan.transferredFrom };
  });
}

/** Apple `signedDate` of a stored transaction payload; 0 when absent. */
function transactionSignedDate(payload: SQL | typeof appleTransactions.payload): SQL {
  return sql`coalesce((${payload}->>'signedDate')::bigint, 0)`;
}

/** The newer of two copies of one transaction, by Apple `signedDate`; ties take the incoming copy. */
export function isAppleTransactionCopyCurrent(
  incoming: Pick<AppleTransactionRow, "payload">,
  stored: Pick<AppleTransactionRow, "payload"> | null,
): boolean {
  const signed = (row: Pick<AppleTransactionRow, "payload">) =>
    typeof row.payload.signedDate === "number" ? row.payload.signedDate : 0;
  return !stored || signed(incoming) >= signed(stored);
}

async function recordTransaction(db: Db, row: AppleTransactionRow): Promise<void> {
  if (!row.transactionId || !row.originalTransactionId) return;
  await db.insert(appleTransactions).values(row).onConflictDoUpdate({
    target: appleTransactions.transactionId,
    // A transaction changes after the fact only by refund or reversal.
    set: {
      revokedAt: sql`excluded.revoked_at`,
      payload: sql`excluded.payload`,
      planId: sql`coalesce(excluded.plan_id, ${appleTransactions.planId})`,
    },
    // Apple data never goes back in time: an older signed copy (a cached
    // client JWS, a retried earlier notification) must not clear a refund
    // recorded from a newer one. A newer reversal still clears it.
    setWhere: sql`${transactionSignedDate(sql`excluded.payload`)} >= ${transactionSignedDate(appleTransactions.payload)}`,
  });
}

async function insertNotification(db: Db, row: AppleNotificationInsert) {
  const inserted = await db.insert(appleNotifications)
    .values(row)
    .onConflictDoNothing({ target: appleNotifications.notificationUuid })
    .returning();
  if (inserted[0]) return { inserted: true, row: inserted[0] };
  const [existing] = await db
    .select()
    .from(appleNotifications)
    .where(eq(appleNotifications.notificationUuid, row.notificationUuid))
    .limit(1);
  if (!existing) throw new Error("Apple notification ledger row disappeared");
  return { inserted: false, row: existing };
}

export function databaseAppleIapStore(db: () => Db = cloudDb): AppleIapStore {
  return {
    accountTokenForUser: (userId) => accountTokenForUser(db(), userId),
    async userIdForAccountToken(token) {
      const [row] = await db()
        .select({ userId: appleAccountTokens.userId })
        .from(appleAccountTokens)
        .where(eq(appleAccountTokens.appAccountToken, token.toLowerCase()))
        .limit(1);
      return row?.userId ?? null;
    },
    async subscription(originalTransactionId) {
      const [row] = await db()
        .select()
        .from(appleSubscriptions)
        .where(eq(appleSubscriptions.originalTransactionId, originalTransactionId))
        .limit(1);
      return row ?? null;
    },
    writeSubscriptionState: (state, claim) => writeSubscriptionState(db(), state, claim),
    recordTransaction: (row) => recordTransaction(db(), row),
    insertNotification: (row) => insertNotification(db(), row),
    async notification(notificationUuid) {
      const [row] = await db()
        .select()
        .from(appleNotifications)
        .where(eq(appleNotifications.notificationUuid, notificationUuid))
        .limit(1);
      return row ?? null;
    },
    async markNotificationProcessed(notificationUuid, processedAt) {
      await db().update(appleNotifications)
        .set({ processedAt, error: null })
        .where(eq(appleNotifications.notificationUuid, notificationUuid));
    },
    async markNotificationFailed(notificationUuid, error, now) {
      // Right-hand sides read the row's values before this update.
      const [row] = await db().update(appleNotifications)
        .set({
          error: error.slice(0, 1000),
          attemptCount: sql`${appleNotifications.attemptCount} + 1`,
          nextAttemptAt: sql`${now.toISOString()}::timestamptz + least(
            ${RETRY_BASE_SECONDS} * power(2, ${appleNotifications.attemptCount}), ${RETRY_MAX_SECONDS}
          ) * interval '1 second'`,
          deadLetteredAt: sql`case when ${appleNotifications.attemptCount} + 1 >= ${APPLE_NOTIFICATION_MAX_ATTEMPTS}
            then coalesce(${appleNotifications.deadLetteredAt}, ${now.toISOString()}::timestamptz)
            else ${appleNotifications.deadLetteredAt} end`,
        })
        .where(eq(appleNotifications.notificationUuid, notificationUuid))
        .returning({ attemptCount: appleNotifications.attemptCount, deadLetteredAt: appleNotifications.deadLetteredAt });
      return { attemptCount: row?.attemptCount ?? 0, deadLettered: Boolean(row?.deadLetteredAt) };
    },
    async markNotificationSkipped(notificationUuid, reason, processedAt) {
      await db().update(appleNotifications)
        .set({ processedAt, error: `skipped: ${reason}`.slice(0, 1000) })
        .where(eq(appleNotifications.notificationUuid, notificationUuid));
    },
    async pendingNotifications(limit, now) {
      return await db()
        .select()
        .from(appleNotifications)
        .where(and(
          isNull(appleNotifications.processedAt),
          isNull(appleNotifications.deadLetteredAt),
          or(isNull(appleNotifications.nextAttemptAt), sql`${appleNotifications.nextAttemptAt} <= ${now.toISOString()}::timestamptz`),
        ))
        .orderBy(sql`coalesce(${appleNotifications.nextAttemptAt}, ${appleNotifications.receivedAt})`, asc(appleNotifications.receivedAt))
        .limit(limit);
    },
    async lapsedSubscriptions(endedBefore, limit) {
      return await db()
        .select({
          originalTransactionId: appleSubscriptions.originalTransactionId,
          userId: appleSubscriptions.userId,
          bundleId: appleSubscriptions.bundleId,
          environment: appleSubscriptions.environment,
          expiresAt: appleSubscriptions.expiresAt,
          gracePeriodExpiresAt: appleSubscriptions.gracePeriodExpiresAt,
          appleCheckedAt: appleSubscriptions.appleCheckedAt,
        })
        .from(appleSubscriptions)
        .where(and(inArray(appleSubscriptions.status, [...APPLE_GRANTING_STATUSES]), lapsedSince(endedBefore)))
        .orderBy(asc(ACCESS_ENDS_AT), asc(appleSubscriptions.originalTransactionId))
        .limit(limit);
    },
    async renewalCheckCandidates({ accessEndsAfter, accessEndsBy, checkedBefore, limit }) {
      return await db()
        .select()
        .from(appleSubscriptions)
        .where(and(
          inArray(appleSubscriptions.status, ["active", "grace_period"]),
          sql`${appleSubscriptions.autoRenewEnabled} is distinct from false`,
          sql`${ACCESS_ENDS_AT} > ${accessEndsAfter.toISOString()}::timestamptz`,
          sql`${ACCESS_ENDS_AT} <= ${accessEndsBy.toISOString()}::timestamptz`,
          or(isNull(appleSubscriptions.appleCheckedAt), lt(appleSubscriptions.appleCheckedAt, checkedBefore)),
        ))
        .orderBy(asc(ACCESS_ENDS_AT), asc(appleSubscriptions.originalTransactionId))
        .limit(limit);
    },
    async markAppleChecked(originalTransactionId, checkedAt) {
      await db().update(appleSubscriptions)
        .set({ appleCheckedAt: checkedAt })
        .where(eq(appleSubscriptions.originalTransactionId, originalTransactionId));
    },
    async notificationHistoryCursor(bundleId, environment) {
      const [row] = await db()
        .select({
          bundleId: appleNotificationHistoryCursors.bundleId,
          environment: appleNotificationHistoryCursors.environment,
          nextStartAt: appleNotificationHistoryCursors.nextStartAt,
          windowStartAt: appleNotificationHistoryCursors.windowStartAt,
          windowEndAt: appleNotificationHistoryCursors.windowEndAt,
          paginationToken: appleNotificationHistoryCursors.paginationToken,
        })
        .from(appleNotificationHistoryCursors)
        .where(and(
          eq(appleNotificationHistoryCursors.bundleId, bundleId),
          eq(appleNotificationHistoryCursors.environment, environment),
        ))
        .limit(1);
      return row ?? null;
    },
    async saveNotificationHistoryCursor(cursor) {
      const values = { ...cursor, updatedAt: new Date() };
      await db().insert(appleNotificationHistoryCursors)
        .values(values)
        .onConflictDoUpdate({
          target: [appleNotificationHistoryCursors.bundleId, appleNotificationHistoryCursors.environment],
          set: {
            nextStartAt: values.nextStartAt,
            windowStartAt: values.windowStartAt,
            windowEndAt: values.windowEndAt,
            paginationToken: values.paginationToken,
            updatedAt: values.updatedAt,
          },
        });
    },
    async latestNotificationSignedDate(environment) {
      const [row] = await db()
        .select({ latest: max(appleNotifications.signedDate) })
        .from(appleNotifications)
        .where(eq(appleNotifications.environment, environment));
      return row?.latest ?? null;
    },
    async markLapseSwept(originalTransactionIds, now) {
      if (originalTransactionIds.length === 0) return;
      await db().update(appleSubscriptions)
        .set({
          status: sql`case ${appleSubscriptions.status}
            when 'active' then 'expired'
            when 'grace_period' then 'billing_retry'
            else ${appleSubscriptions.status} end`,
          updatedAt: now,
        })
        .where(and(
          inArray(appleSubscriptions.originalTransactionId, [...originalTransactionIds]),
          inArray(appleSubscriptions.status, [...APPLE_GRANTING_STATUSES]),
          lapsedSince(now),
        ));
    },
  };
}
