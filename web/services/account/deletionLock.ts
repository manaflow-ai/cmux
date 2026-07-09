import { createHash } from "node:crypto";

export function accountDeletionUserHash(userId: string): string {
  return createHash("sha256").update(userId).digest("hex");
}

export function accountDeletionAdvisoryLockKey(userId: string): string {
  return `account-deletion:${accountDeletionUserHash(userId)}`;
}

export function isBlockingAccountDeletionStatus(status: string): boolean {
  return status === "pending" || status === "in_progress";
}
