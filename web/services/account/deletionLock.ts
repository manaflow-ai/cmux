import { createHash } from "node:crypto";
import { eq, sql } from "drizzle-orm";
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

export function isBlockingAccountDeletionStatus(status: string): boolean {
  return status !== "failed";
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
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  if (deletion?.userIdHash !== userIdHash || !isBlockingAccountDeletionStatus(deletion.status)) return;
  throw new AccountDeletionMutationBlockedError(userId);
}
