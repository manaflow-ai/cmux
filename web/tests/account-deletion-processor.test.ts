import { beforeEach, describe, expect, test } from "bun:test";
import {
  processAccountDeletionForUser,
  processPendingAccountDeletions,
  type AccountDeletionProcessorDependencies,
} from "../services/account/deletionProcessor";
import type { AccountDeletionJob } from "../services/account/deletion";

const calls: string[] = [];
let claimResult = true;
let cleanupError: Error | null = null;
let stackDeleteError: Error | null = null;
let pendingJobs: AccountDeletionJob[] = [];

beforeEach(() => {
  calls.length = 0;
  claimResult = true;
  cleanupError = null;
  stackDeleteError = null;
  pendingJobs = [];
});

describe("account deletion processor", () => {
  test("skips cleanup when another worker already owns the deletion job", async () => {
    claimResult = false;

    const result = await processAccountDeletionForUser({ userId: "user-1" }, dependencies());

    expect(result).toBe("skipped");
    expect(calls).toEqual(["claim:user-1"]);
  });

  test("runs cleanup and external deletion before marking the job completed", async () => {
    const result = await processAccountDeletionForUser({ userId: "user-1" }, dependencies());

    expect(result).toBe("processed");
    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "cleanup:user-1",
      "posthog:user-1",
      "completed:user-1",
      "stack-delete:user-1",
    ]);
  });

  test("records failures so the durable job can be retried", async () => {
    cleanupError = new Error("cleanup failed");

    await expect(
      processAccountDeletionForUser({ userId: "user-1" }, dependencies()),
    ).rejects.toThrow("cleanup failed");

    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "cleanup:user-1",
      "failed:user-1:cleanup failed",
    ]);
  });

  test("records a retryable failure when Stack deletion fails after completion is marked", async () => {
    stackDeleteError = new Error("Stack delete failed");

    await expect(
      processAccountDeletionForUser({ userId: "user-1" }, dependencies()),
    ).rejects.toThrow("Stack delete failed");

    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "cleanup:user-1",
      "posthog:user-1",
      "completed:user-1",
      "stack-delete:user-1",
      "failed:user-1:Stack delete failed",
    ]);
  });

  test("processes pending jobs and continues after a failed job", async () => {
    pendingJobs = [
      { userId: "user-1", userIdHash: "hash-1", status: "pending" },
      { userId: "user-2", userIdHash: "hash-2", status: "failed" },
    ];
    const deps = dependencies({
      deleteCmuxAccountData: async ({ userId }) => {
        calls.push(`cleanup:${userId}`);
        if (userId === "user-1") throw new Error("cleanup failed");
      },
    });

    const result = await processPendingAccountDeletions({ limit: 2 }, deps);

    expect(result).toEqual({ scanned: 2, processed: 1, skipped: 0, failed: 1 });
    expect(calls).toContain("failed:user-1:cleanup failed");
    expect(calls).toContain("completed:user-2");
  });
});

function dependencies(
  overrides: Partial<AccountDeletionProcessorDependencies> = {},
): AccountDeletionProcessorDependencies {
  return {
    claimAccountDeletionProcessing: async ({ userId }) => {
      calls.push(`claim:${userId}`);
      return claimResult;
    },
    deleteCmuxAccountData: async ({ userId }) => {
      calls.push(`cleanup:${userId}`);
      if (cleanupError) throw cleanupError;
    },
    deletePostHogPersonData: async (userId) => {
      calls.push(`posthog:${userId}`);
    },
    loadStackUser: async (userId) => {
      calls.push(`load-stack:${userId}`);
      return {
        id: userId,
        clientReadOnlyMetadata: {},
        update: async () => {},
        delete: async () => {
          calls.push(`stack-delete:${userId}`);
          if (stackDeleteError) throw stackDeleteError;
        },
      };
    },
    markAccountDeletionCompleted: async ({ userId }) => {
      calls.push(`completed:${userId}`);
    },
    markAccountDeletionFailed: async ({ userId, error }) => {
      calls.push(`failed:${userId}:${error instanceof Error ? error.message : "unknown"}`);
    },
    listPendingAccountDeletionJobs: async () => pendingJobs,
    ...overrides,
  };
}
