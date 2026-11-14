// In-memory AppleIapStore with the same contract as the Postgres store
// (services/billing/apple/store.ts): forward-only subscription state,
// ownership decided by the shared planAppleSubscriptionWrite, idempotent
// ledger rows. The DB behavior
// test proves the real store keeps the same contract.

import { randomUUID } from "node:crypto";

import {
  APPLE_GRANTING_STATUSES,
  appleAccessEndsAt,
  appleSweptStatus,
  isAppleTransactionCopyCurrent,
  planAppleSubscriptionWrite,
  type AppleIapStore,
  type AppleNotificationHistoryCursor,
  type AppleNotificationRow,
  type AppleSubscriptionRow,
} from "../../services/billing/apple/store";
import type { AppleTransactionRow } from "../../services/billing/apple/state";

export type MemoryAppleStore = AppleIapStore & {
  readonly tokens: Map<string, string>;
  readonly subscriptions: Map<string, AppleSubscriptionRow>;
  readonly transactions: Map<string, AppleTransactionRow>;
  readonly notifications: Map<string, AppleNotificationRow>;
  readonly historyCursors: Map<string, AppleNotificationHistoryCursor>;
};

// Retry backoff as the database store computes it in SQL (store.ts:
// appleNotificationRetryDelayMs, APPLE_NOTIFICATION_MAX_ATTEMPTS). Kept as
// literals so this double loads against older store code too;
// apple-iap-retry-backoff.test.ts pins both to the store's exports.
export const MEMORY_MAX_ATTEMPTS = 12;
export function memoryRetryDelayMs(attemptCount: number): number {
  return Math.min(300 * 2 ** Math.max(0, attemptCount - 1), 12 * 60 * 60) * 1000;
}

function cursorKey(bundleId: string, environment: string): string {
  return `${environment}:${bundleId}`;
}

function isLapsed(row: AppleSubscriptionRow, now: Date): boolean {
  const endsAt = appleAccessEndsAt(row);
  return (APPLE_GRANTING_STATUSES as readonly string[]).includes(row.status) &&
    endsAt !== null && endsAt < now && row.updatedAt < endsAt;
}

export function memoryAppleStore(): MemoryAppleStore {
  const tokens = new Map<string, string>();
  const subscriptions = new Map<string, AppleSubscriptionRow>();
  const transactions = new Map<string, AppleTransactionRow>();
  const notifications = new Map<string, AppleNotificationRow>();
  const historyCursors = new Map<string, AppleNotificationHistoryCursor>();
  return {
    tokens,
    subscriptions,
    transactions,
    notifications,
    historyCursors,
    async accountTokenForUser(userId) {
      let token = tokens.get(userId);
      if (!token) {
        token = randomUUID();
        tokens.set(userId, token);
      }
      return token;
    },
    async userIdForAccountToken(token) {
      for (const [userId, candidate] of tokens) if (candidate === token.toLowerCase()) return userId;
      return null;
    },
    async subscription(id) {
      return subscriptions.get(id) ?? null;
    },
    async writeSubscriptionState(state, claim) {
      const previous = subscriptions.get(state.originalTransactionId) ?? null;
      const plan = planAppleSubscriptionWrite(previous, state, claim);
      if (plan.kind === "stale") return { applied: false, previous: previous!, current: previous!, transferredFrom: null };
      const now = new Date();
      const current: AppleSubscriptionRow = {
        ...state,
        userId: plan.userId,
        appleCheckedAt: previous?.appleCheckedAt ?? null,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
      };
      subscriptions.set(state.originalTransactionId, current);
      return { applied: true, previous, current, transferredFrom: plan.transferredFrom };
    },
    async recordTransaction(row) {
      if (!row.transactionId) return;
      if (!isAppleTransactionCopyCurrent(row, transactions.get(row.transactionId) ?? null)) return;
      transactions.set(row.transactionId, row);
    },
    async insertNotification(row) {
      const existing = notifications.get(row.notificationUuid);
      if (existing) return { inserted: false, row: existing };
      const created: AppleNotificationRow = {
        ...row,
        receivedAt: new Date(),
        processedAt: null,
        error: null,
        attemptCount: 0,
        nextAttemptAt: null,
        deadLetteredAt: null,
      };
      notifications.set(row.notificationUuid, created);
      return { inserted: true, row: created };
    },
    async markNotificationProcessed(uuid, processedAt) {
      const row = notifications.get(uuid);
      if (row) notifications.set(uuid, { ...row, processedAt, error: null });
    },
    async notification(uuid) {
      return notifications.get(uuid) ?? null;
    },
    async markNotificationFailed(uuid, error, now) {
      const row = notifications.get(uuid);
      if (!row) return { attemptCount: 0, deadLettered: false };
      const attemptCount = row.attemptCount + 1;
      const deadLetteredAt = attemptCount >= MEMORY_MAX_ATTEMPTS ? row.deadLetteredAt ?? now : row.deadLetteredAt;
      notifications.set(uuid, {
        ...row,
        error,
        attemptCount,
        nextAttemptAt: new Date(now.getTime() + memoryRetryDelayMs(attemptCount)),
        deadLetteredAt,
      });
      return { attemptCount, deadLettered: deadLetteredAt !== null };
    },
    async markNotificationSkipped(uuid, reason, processedAt) {
      const row = notifications.get(uuid);
      if (row) notifications.set(uuid, { ...row, processedAt, error: `skipped: ${reason}` });
    },
    async pendingNotifications(limit, now) {
      const due = (row: AppleNotificationRow) => (row.nextAttemptAt ?? row.receivedAt).getTime();
      return [...notifications.values()]
        .filter((row) => row.processedAt === null && row.deadLetteredAt === null &&
          (row.nextAttemptAt === null || row.nextAttemptAt <= now))
        .sort((a, b) => due(a) - due(b))
        .slice(0, limit);
    },
    async lapsedSubscriptions(endedBefore, limit) {
      return [...subscriptions.values()]
        .filter((row) => isLapsed(row, endedBefore))
        .sort((a, b) => appleAccessEndsAt(a)!.getTime() - appleAccessEndsAt(b)!.getTime())
        .slice(0, limit)
        .map((row) => ({
          originalTransactionId: row.originalTransactionId,
          userId: row.userId,
          bundleId: row.bundleId,
          environment: row.environment,
          expiresAt: row.expiresAt,
          gracePeriodExpiresAt: row.gracePeriodExpiresAt,
          appleCheckedAt: row.appleCheckedAt,
        }));
    },
    async renewalCheckCandidates({ accessEndsAfter, accessEndsBy, checkedBefore, limit }) {
      return [...subscriptions.values()]
        .filter((row) => {
          const endsAt = appleAccessEndsAt(row);
          return (row.status === "active" || row.status === "grace_period") &&
            endsAt !== null && endsAt > accessEndsAfter && endsAt <= accessEndsBy &&
            (row.appleCheckedAt === null || row.appleCheckedAt < checkedBefore);
        })
        .sort((a, b) => appleAccessEndsAt(a)!.getTime() - appleAccessEndsAt(b)!.getTime())
        .slice(0, limit);
    },
    async markAppleChecked(id, checkedAt) {
      const row = subscriptions.get(id);
      if (row) subscriptions.set(id, { ...row, appleCheckedAt: checkedAt });
    },
    async notificationHistoryCursor(bundleId, environment) {
      return historyCursors.get(cursorKey(bundleId, environment)) ?? null;
    },
    async saveNotificationHistoryCursor(cursor) {
      historyCursors.set(cursorKey(cursor.bundleId, cursor.environment), { ...cursor });
    },

    async markLapseSwept(ids, now) {
      for (const id of ids) {
        const row = subscriptions.get(id);
        if (!row || !isLapsed(row, now)) continue;
        subscriptions.set(id, { ...row, status: appleSweptStatus(row.status), updatedAt: now });
      }
    },
  };
}
