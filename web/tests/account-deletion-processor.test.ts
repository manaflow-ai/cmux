import { beforeEach, describe, expect, test } from "bun:test";
import type { AccountDeletionJob, AccountDeletionStatus } from "../services/account/deletion";
import type { AccountDeletionProcessorDependencies } from "../services/account/deletionProcessor";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const {
  processAccountDeletionForUser,
  processPendingAccountDeletions,
} = await import("../services/account/deletionProcessor");

const calls: string[] = [];
let claimResult: AccountDeletionStatus | null = "pending";
let cleanupError: Error | null = null;
let stackDeleteError: Error | null = null;
let pendingJobs: AccountDeletionJob[] = [];

beforeEach(() => {
  calls.length = 0;
  claimResult = "pending";
  cleanupError = null;
  stackDeleteError = null;
  pendingJobs = [];
});

describe("account deletion processor", () => {
  test("skips cleanup when another worker already owns the deletion job", async () => {
    claimResult = null;

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
      "list-analytics-identities:user-1",
      "posthog:user-1:user-1,anon-1",
      "delete-analytics-identities:user-1",
      "stack-delete-pending:user-1",
      "stack-delete:user-1",
      "completed:user-1",
    ]);
  });

  test("keeps cleanup-started failures blocking so the durable job can retry", async () => {
    cleanupError = new Error("cleanup failed");

    await expect(
      processAccountDeletionForUser({ userId: "user-1" }, dependencies()),
    ).rejects.toThrow("cleanup failed");

    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "cleanup:user-1",
      "retry-pending:user-1:cleanup failed",
    ]);
  });

  test("records non-blocking failures before cleanup starts", async () => {
    await expect(
      processAccountDeletionForUser({ userId: "user-1" }, dependencies({
        loadStackUser: async (userId) => {
          calls.push(`load-stack:${userId}`);
          throw new Error("Stack lookup failed");
        },
      })),
    ).rejects.toThrow("Stack lookup failed");

    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "failed:user-1:Stack lookup failed",
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
      "list-analytics-identities:user-1",
      "posthog:user-1:user-1,anon-1",
      "delete-analytics-identities:user-1",
      "stack-delete-pending:user-1",
      "stack-delete:user-1",
      "stack-delete-pending:user-1:Stack delete failed",
    ]);
  });

  test("resumes Stack deletion without replaying cmux or PostHog cleanup", async () => {
    claimResult = "stack_delete_pending";

    const result = await processAccountDeletionForUser({ userId: "user-1" }, dependencies());

    expect(result).toBe("processed");
    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "stack-delete:user-1",
      "completed:user-1",
    ]);
  });

  test("continues a claimed Stack deletion without replaying cleanup", async () => {
    claimResult = "stack_delete_in_progress";

    const result = await processAccountDeletionForUser({ userId: "user-1" }, dependencies());

    expect(result).toBe("processed");
    expect(calls).toEqual([
      "claim:user-1",
      "load-stack:user-1",
      "stack-delete:user-1",
      "completed:user-1",
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
    expect(calls).toContain("retry-pending:user-1:cleanup failed");
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
    deleteIOSAnalyticsIdentities: async ({ userId }) => {
      calls.push(`delete-analytics-identities:${userId}`);
    },
    deletePostHogPersonData: async (userId, distinctIds) => {
      calls.push(`posthog:${userId}:${distinctIds.join(",")}`);
    },
    listPostHogDeletionDistinctIds: async ({ userId }) => {
      calls.push(`list-analytics-identities:${userId}`);
      return [userId, "anon-1"];
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
    clearStackUserDeletionInProgress: async (user) => {
      calls.push(`clear-deleting:${user.id}`);
    },
    markAccountDeletionCompleted: async ({ userId }) => {
      calls.push(`completed:${userId}`);
    },
    markAccountDeletionFailed: async ({ userId, error }) => {
      calls.push(`failed:${userId}:${error instanceof Error ? error.message : "unknown"}`);
    },
    markAccountDeletionRetryPending: async ({ userId, error }) => {
      calls.push(`retry-pending:${userId}:${error instanceof Error ? error.message : "unknown"}`);
    },
    markAccountDeletionStackDeletePending: async ({ userId, error }) => {
      calls.push(error
        ? `stack-delete-pending:${userId}:${error instanceof Error ? error.message : "unknown"}`
        : `stack-delete-pending:${userId}`);
    },
    listPendingAccountDeletionJobs: async () => pendingJobs,
    ...overrides,
  };
}
