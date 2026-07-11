import { createHash } from "node:crypto";
import { eq, inArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { accountDeletionTombstones } from "../../db/schema";

type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

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
  const userIdHashes = [
    ...new Set(
      userIds
        .filter((userId) => userId.length > 0)
        .map(accountDeletionUserHash),
    ),
  ];
  if (userIdHashes.length === 0) return false;

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
