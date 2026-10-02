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
  planAppleSubscriptionWrite,
  type AppleIapStore,
  type AppleNotificationRow,
  type AppleSubscriptionRow,
} from "../../services/billing/apple/store";
import type { AppleTransactionRow } from "../../services/billing/apple/state";

export type MemoryAppleStore = AppleIapStore & {
  readonly tokens: Map<string, string>;
  readonly subscriptions: Map<string, AppleSubscriptionRow>;
  readonly transactions: Map<string, AppleTransactionRow>;
  readonly notifications: Map<string, AppleNotificationRow>;
};

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
  return {
    tokens,
    subscriptions,
    transactions,
    notifications,
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
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
      };
      subscriptions.set(state.originalTransactionId, current);
      return { applied: true, previous, current, transferredFrom: plan.transferredFrom };
    },
    async recordTransaction(row) {
      if (!row.transactionId) return;
      transactions.set(row.transactionId, row);
    },
    async insertNotification(row) {
      const existing = notifications.get(row.notificationUuid);
      if (existing) return { inserted: false, row: existing };
      const created: AppleNotificationRow = { ...row, receivedAt: new Date(), processedAt: null, error: null };
      notifications.set(row.notificationUuid, created);
      return { inserted: true, row: created };
    },
    async markNotificationProcessed(uuid, processedAt) {
      const row = notifications.get(uuid);
      if (row) notifications.set(uuid, { ...row, processedAt, error: null });
    },
    async markNotificationFailed(uuid, error) {
      const row = notifications.get(uuid);
      if (row) notifications.set(uuid, { ...row, error });
    },
    async markNotificationSkipped(uuid, reason, processedAt) {
      const row = notifications.get(uuid);
      if (row) notifications.set(uuid, { ...row, processedAt, error: `skipped: ${reason}` });
    },
    async pendingNotifications(limit) {
      return [...notifications.values()].filter((row) => row.processedAt === null).slice(0, limit);
    },
    async lapsedSubscriptions(now, limit) {
      return [...subscriptions.values()]
        .filter((row) => isLapsed(row, now))
        .sort((a, b) => appleAccessEndsAt(a)!.getTime() - appleAccessEndsAt(b)!.getTime())
        .slice(0, limit)
        .map((row) => ({ originalTransactionId: row.originalTransactionId, userId: row.userId }));
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
