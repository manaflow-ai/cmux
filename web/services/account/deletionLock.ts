import { createHash } from "node:crypto";
import { eq, inArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { accountDeletionTombstones } from "../../db/schema";

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

export function accountDeletionUserHash(userId: string): string {
  return createHash("sha256").update(userId).digest("hex");
}

export function accountDeletionAdvisoryLockKey(userId: string): string {
  return `account-deletion:${accountDeletionUserHash(userId)}`;
}

export const ACCOUNT_DELETION_TOMBSTONE_LEASE_MS = 15 * 60 * 1000;

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

export async function withAccountDeletionIdentityLocks<T>(
  db: ReturnType<typeof cloudDb>,
  userIds: readonly string[],
  operation: () => Promise<T>,
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

  return await db.transaction(async (tx) => {
    // Every account mutation and deletion start uses this same lock namespace.
    // Sorted acquisition avoids deadlocks for anonymous batches containing more
    // than one client identity. Holding the transaction through the external
    // forward closes the check/forward race: deletion either waits and removes
    // the forwarded data, or wins first and leaves a tombstone this check sees.
    for (const [, userId] of identities) {
      await tx.execute(
        sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`,
      );
    }
    if (await hasBlockingAccountDeletionIdentityHashes(tx, identities.map(([hash]) => hash))) {
      return { kind: "blocked" };
    }
    return { kind: "completed", value: await operation() };
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
