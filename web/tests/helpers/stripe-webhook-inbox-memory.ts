import type {
  StripeWebhookClaim,
  StripeWebhookInbox,
  StripeWebhookInboxEntry,
} from "../../services/billing/stripeWebhookInbox";

export type MemoryStripeWebhookRow = StripeWebhookInboxEntry & {
  processedAt: Date | null;
  skipReason: string | null;
  error: string | null;
  attempts: number;
  nextAttemptAt: Date;
  leaseExpiresAt: Date | null;
  storedAt: Date;
};

/** An in-memory `StripeWebhookInbox` with the store's lease and per-object rules. */
export function memoryStripeWebhookInbox(clock: () => Date = () => new Date()) {
  const rows = new Map<string, MemoryStripeWebhookRow>();
  const running = new Map<string, string | null>();
  const held = (claim: StripeWebhookClaim) => {
    const row = rows.get(claim.id);
    return row && row.attempts === claim.attempts && !row.processedAt ? row : null;
  };
  const inbox: StripeWebhookInbox = {
    async record(entry) {
      const existing = rows.get(entry.id);
      if (existing) return { processed: Boolean(existing.processedAt) };
      const now = clock();
      rows.set(entry.id, {
        ...entry,
        processedAt: null,
        skipReason: null,
        error: null,
        attempts: 0,
        nextAttemptAt: new Date(now.getTime() + 120_000),
        leaseExpiresAt: null,
        storedAt: now,
      });
      return { processed: false };
    },
    async claim(id, now, leaseUntil) {
      const row = rows.get(id);
      if (!row || row.processedAt || running.has(id)) return null;
      if (row.leaseExpiresAt && row.leaseExpiresAt > now) return null;
      if (row.objectKey) {
        if ([...running.values()].includes(row.objectKey)) return null;
        for (const other of rows.values()) {
          if (
            other.id !== id &&
            other.objectKey === row.objectKey &&
            !other.processedAt &&
            other.leaseExpiresAt &&
            other.leaseExpiresAt > now
          ) return null;
        }
      }
      row.attempts += 1;
      row.leaseExpiresAt = leaseUntil;
      return { id, attempts: row.attempts };
    },
    async runExclusive(claim, objectKey, operation) {
      const row = held(claim);
      if (!row || running.has(claim.id)) return null;
      if (objectKey && [...running.values()].includes(objectKey)) return null;
      if (objectKey && [...rows.values()].some((other) => other.id !== claim.id &&
        other.objectKey === objectKey && !other.processedAt && other.leaseExpiresAt && other.leaseExpiresAt > clock())) return null;
      row.objectKey = objectKey;
      running.set(claim.id, objectKey);
      try { return await operation(inbox); }
      finally { running.delete(claim.id); }
    },
    async supersededBy(entry, types) {
      if (!entry.objectKey || !entry.createdAt) return null;
      for (const other of rows.values()) {
        if (
          other.id !== entry.id &&
          other.objectKey === entry.objectKey &&
          other.createdAt &&
          other.createdAt > entry.createdAt &&
          other.processedAt &&
          other.skipReason === null &&
          types.includes(other.type)
        ) return other.id;
      }
      return null;
    },
    async complete(claim, skipReason) {
      const row = held(claim);
      if (!row) return false;
      Object.assign(row, { processedAt: clock(), skipReason, error: null, leaseExpiresAt: null });
      return true;
    },
    async fail(claim, error, nextAttemptAt) {
      const row = held(claim);
      if (!row) return false;
      Object.assign(row, { error, leaseExpiresAt: null, nextAttemptAt });
      return true;
    },
    async due(now, since, limit) {
      return [...rows.values()]
        .filter((row) =>
          !row.processedAt &&
          row.nextAttemptAt <= now &&
          row.storedAt >= since &&
          (!row.leaseExpiresAt || row.leaseExpiresAt <= now))
        .sort((a, b) => a.nextAttemptAt.getTime() - b.nextAttemptAt.getTime() || a.id.localeCompare(b.id))
        .slice(0, limit)
        .map((row) => row.id);
    },
  };
  return { inbox, rows };
}
