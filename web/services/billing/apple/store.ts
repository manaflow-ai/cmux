// Postgres persistence for iOS in-app purchases. Every write is idempotent:
// account tokens are minted once per user, transactions and notifications
// are keyed by Apple's ids, and subscription state only moves forward in
// Apple `signedDate` order.

import { randomUUID } from "node:crypto";
import { and, asc, eq, gt, inArray, isNull, lt, sql } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import {
  appleAccountTokens,
  appleNotifications,
  appleSubscriptions,
  appleTransactions,
} from "../../../db/schema";
import type { AppleSubscriptionState, AppleTransactionRow } from "./state";

type Db = ReturnType<typeof cloudDb>;

export type AppleSubscriptionRow = typeof appleSubscriptions.$inferSelect;
export type AppleNotificationRow = typeof appleNotifications.$inferSelect;

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
};

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
  writeSubscriptionState(state: AppleSubscriptionState, userId: string): Promise<AppleSubscriptionWrite>;
  recordTransaction(row: AppleTransactionRow): Promise<void>;
  /** Inserts the ledger row; false when the notification UUID already exists. */
  insertNotification(row: AppleNotificationInsert): Promise<{ inserted: boolean; row: AppleNotificationRow }>;
  markNotificationProcessed(notificationUuid: string, processedAt: Date): Promise<void>;
  markNotificationFailed(notificationUuid: string, error: string): Promise<void>;
  /** Closes a notification that can never apply, keeping the reason. */
  markNotificationSkipped(notificationUuid: string, reason: string, processedAt: Date): Promise<void>;
  /** Ledger rows still owed an entitlement application (failed or never run), oldest first. */
  pendingNotifications(limit: number): Promise<AppleNotificationRow[]>;
  /** Users whose granting-looking subscription passed its expiry recently. */
  usersWithLapsedGrants(now: Date, since: Date, limit: number): Promise<string[]>;
};

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
  userId: string,
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
    if (previous && previous.userId !== userId) throw new AppleOwnershipError(state.originalTransactionId);
    if (previous && previous.stateSignedAt.getTime() > state.stateSignedAt.getTime()) {
      return { applied: false, previous, current: previous };
    }
    const values = subscriptionValues(state, userId, new Date());
    const [current] = previous
      ? await tx.update(appleSubscriptions)
        .set(values)
        .where(eq(appleSubscriptions.originalTransactionId, state.originalTransactionId))
        .returning()
      : await tx.insert(appleSubscriptions).values(values).returning();
    if (!current) throw new Error("Apple subscription write returned no row");
    return { applied: true, previous: previous ?? null, current };
  });
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
    writeSubscriptionState: (state, userId) => writeSubscriptionState(db(), state, userId),
    recordTransaction: (row) => recordTransaction(db(), row),
    insertNotification: (row) => insertNotification(db(), row),
    async markNotificationProcessed(notificationUuid, processedAt) {
      await db().update(appleNotifications)
        .set({ processedAt, error: null })
        .where(eq(appleNotifications.notificationUuid, notificationUuid));
    },
    async markNotificationFailed(notificationUuid, error) {
      await db().update(appleNotifications)
        .set({ error: error.slice(0, 1000) })
        .where(eq(appleNotifications.notificationUuid, notificationUuid));
    },
    async markNotificationSkipped(notificationUuid, reason, processedAt) {
      await db().update(appleNotifications)
        .set({ processedAt, error: `skipped: ${reason}`.slice(0, 1000) })
        .where(eq(appleNotifications.notificationUuid, notificationUuid));
    },
    async pendingNotifications(limit) {
      return await db()
        .select()
        .from(appleNotifications)
        .where(isNull(appleNotifications.processedAt))
        .orderBy(asc(appleNotifications.receivedAt))
        .limit(limit);
    },
    async usersWithLapsedGrants(now, since, limit) {
      const rows = await db()
        .selectDistinct({ userId: appleSubscriptions.userId })
        .from(appleSubscriptions)
        .where(and(
          inArray(appleSubscriptions.status, ["active", "grace_period", "billing_retry"]),
          lt(appleSubscriptions.expiresAt, now),
          gt(appleSubscriptions.expiresAt, since),
        ))
        .limit(limit);
      return rows.map((row) => row.userId);
    },
  };
}
