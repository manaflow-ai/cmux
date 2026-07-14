import { createHash, randomUUID } from "node:crypto";
import { and, eq, gt, inArray, lt, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { accountAnalyticsForwardLeases, accountDeletionTombstones } from "../../db/schema";

type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];
type AccountDeletionQueryExecutor = Pick<CloudDbTransaction, "select">;

export type AccountDeletionIdentityOperationResult<T> =
  | { readonly kind: "blocked" }
  | { readonly kind: "completed"; readonly value: T };

export class AccountDeletionMutationBlockedError extends Error {
  constructor(readonly userId: string) {
    super("Account deletion is in progress.");
    this.name = "AccountDeletionMutationBlockedError";
  }
}

export class AccountDeletionAnalyticsForwardInProgressError extends Error {
  constructor(readonly userId: string) {
    super("An analytics forward for this account is still in progress.");
    this.name = "AccountDeletionAnalyticsForwardInProgressError";
  }
}

export function accountDeletionUserHash(userId: string): string {
  return createHash("sha256").update(userId).digest("hex");
}

export function accountDeletionAdvisoryLockKey(userId: string): string {
  return `account-deletion:${accountDeletionUserHash(userId)}`;
}

export const ACCOUNT_DELETION_TOMBSTONE_LEASE_MS = 15 * 60 * 1000;
export const ACCOUNT_ANALYTICS_FORWARD_LEASE_MS = 30 * 1000;

export function isBlockingAccountDeletionStatus(status: string): boolean {
  return status !== "failed";
}

export function isStaleAccountDeletionTombstone(
  updatedAt: Date | null,
  now: Date = new Date(),
): boolean {
  return !updatedAt || now.getTime() - updatedAt.getTime() >= ACCOUNT_DELETION_TOMBSTONE_LEASE_MS;
}

export function isBlockingAccountDeletionTombstone(
  tombstone: {
    readonly status: string;
    readonly updatedAt: Date | null;
  },
  now: Date = new Date(),
): boolean {
  if (!isBlockingAccountDeletionStatus(tombstone.status)) return false;
  if (tombstone.status === "completed" || tombstone.status === "cleanup_incomplete") return true;
  return !isStaleAccountDeletionTombstone(tombstone.updatedAt, now);
}

export async function hasBlockingAccountDeletionIdentity(
  db: ReturnType<typeof cloudDb>,
  userIds: readonly string[],
): Promise<boolean> {
  const userIdHashes = uniqueAccountDeletionIdentityHashes(userIds);
  if (userIdHashes.length === 0) return false;

  return await hasBlockingAccountDeletionIdentityHashes(db, userIdHashes);
}

function uniqueAccountDeletionIdentityHashes(userIds: readonly string[]): string[] {
  return [
    ...new Set(
      userIds
        .filter((userId) => userId.length > 0)
        .map(accountDeletionUserHash),
    ),
  ];
}

export async function withAccountDeletionAnalyticsForwardLease<T>(
  db: ReturnType<typeof cloudDb>,
  userIds: readonly string[],
  operation: () => Promise<T>,
  releaseLeaseWhen: (value: T) => boolean = () => true,
  now: () => Date = () => new Date(),
): Promise<AccountDeletionIdentityOperationResult<T>> {
  const identitiesByHash = new Map<string, string>();
  for (const userId of userIds) {
    if (userId.length === 0) continue;
    identitiesByHash.set(accountDeletionUserHash(userId), userId);
  }
  const identities = [...identitiesByHash.entries()].sort(([leftHash], [rightHash]) =>
    leftHash.localeCompare(rightHash)
  );
  if (identities.length === 0) {
    return { kind: "completed", value: await operation() };
  }

  const operationId = randomUUID();
  const reservation = await db.transaction(async (tx) => {
    // Every account mutation and deletion start uses this same lock namespace.
    // Sorted acquisition avoids deadlocks for anonymous batches containing more
    // than one client identity. The durable lease survives process boundaries,
    // while the transaction ends before PostHog I/O starts.
    for (const [, userId] of identities) {
      await tx.execute(
        sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`,
      );
    }
    if (await hasBlockingAccountDeletionIdentityHashes(tx, identities.map(([hash]) => hash))) {
      return { kind: "blocked" } as const;
    }
    // Start the lease only after every advisory lock and tombstone check. A
    // contended transaction must not begin PostHog I/O with an already-expired
    // reservation that account deletion can prune underneath it.
    const reservedAt = now();
    const expiresAt = new Date(reservedAt.getTime() + ACCOUNT_ANALYTICS_FORWARD_LEASE_MS);
    // Ordinary analytics traffic prunes expired leases for every identity.
    // This bounds retained rows to the ingress volume within one lease window,
    // including after an outage populated one-off anonymous identities.
    await tx.delete(accountAnalyticsForwardLeases).where(
      lt(accountAnalyticsForwardLeases.expiresAt, reservedAt),
    );
    await tx.insert(accountAnalyticsForwardLeases).values(
      identities.map(([userIdHash]) => ({ operationId, userIdHash, expiresAt })),
    );
    return { kind: "reserved" } as const;
  });
  if (reservation.kind === "blocked") return reservation;

  let releaseLease = false;
  try {
    const value = await operation();
    releaseLease = releaseLeaseWhen(value);
    return { kind: "completed", value };
  } finally {
    // A failed cleanup leaves a bounded durable lease. Account deletion rejects
    // active leases and discards expired ones, so a process crash or ambiguous
    // network timeout fails closed without blocking deletion forever.
    if (releaseLease) {
      await releaseAccountAnalyticsForwardLease(db, identities, operationId).catch(() => undefined);
    }
  }
}

async function releaseAccountAnalyticsForwardLease(
  db: ReturnType<typeof cloudDb>,
  identities: readonly (readonly [string, string])[],
  operationId: string,
): Promise<void> {
  await db.transaction(async (tx) => {
    for (const [, userId] of identities) {
      await tx.execute(
        sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`,
      );
    }
    await tx
      .delete(accountAnalyticsForwardLeases)
      .where(eq(accountAnalyticsForwardLeases.operationId, operationId));
  });
}

export async function assertNoAccountAnalyticsForwardInProgress(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  now: Date = new Date(),
): Promise<void> {
  const userIdHash = accountDeletionUserHash(userId);
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`,
    );
    await tx.delete(accountAnalyticsForwardLeases).where(
      and(
        eq(accountAnalyticsForwardLeases.userIdHash, userIdHash),
        lt(accountAnalyticsForwardLeases.expiresAt, now),
      ),
    );
    const [activeLease] = await tx
      .select({ id: accountAnalyticsForwardLeases.id })
      .from(accountAnalyticsForwardLeases)
      .where(and(
        eq(accountAnalyticsForwardLeases.userIdHash, userIdHash),
        gt(accountAnalyticsForwardLeases.expiresAt, now),
      ))
      .limit(1);
    if (activeLease) throw new AccountDeletionAnalyticsForwardInProgressError(userId);
  });
}

async function hasBlockingAccountDeletionIdentityHashes(
  db: AccountDeletionQueryExecutor,
  userIdHashes: readonly string[],
): Promise<boolean> {

  const tombstones = await db
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
      analyticsDeletedAt: accountDeletionTombstones.analyticsDeletedAt,
    })
    .from(accountDeletionTombstones)
    .where(inArray(accountDeletionTombstones.userIdHash, userIdHashes));

  return tombstones.some((tombstone) =>
    userIdHashes.includes(tombstone.userIdHash) &&
      (tombstone.analyticsDeletedAt !== null || isBlockingAccountDeletionTombstone(tombstone)),
  );
}

export async function assertAccountDeletionUserMutationAllowed(
  tx: CloudDbTransaction,
  userId: string,
): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`);
  const userIdHash = accountDeletionUserHash(userId);
  const [deletion] = await tx
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  if (
    deletion?.userIdHash !== userIdHash ||
    !isBlockingAccountDeletionTombstone(deletion)
  ) return;
  throw new AccountDeletionMutationBlockedError(userId);
}
