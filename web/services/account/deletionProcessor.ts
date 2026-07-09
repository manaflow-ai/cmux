import { getStackServerApp } from "../../app/lib/stack";
import {
  deleteIOSAnalyticsIdentities,
  listPostHogDeletionDistinctIds,
} from "../analytics/iosAnalyticsIdentities";
import { deletePostHogPersonData } from "../analytics/posthogDeletion";
import {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  listPendingAccountDeletionJobs,
  markAccountDeletionCompleted,
  markAccountDeletionFailed,
  markAccountDeletionStackDeletePending,
  type AccountDeletionJob,
  type AccountDeletionStatus,
  type StackAccountDeletionMetadataUser,
} from "./deletion";

type StackAccountDeletionUser = StackAccountDeletionMetadataUser & {
  readonly id: string;
  delete(): Promise<void>;
};

export type AccountDeletionProcessorDependencies = {
  readonly claimAccountDeletionProcessing: (input: { readonly userId: string }) => Promise<AccountDeletionStatus | null>;
  readonly deleteCmuxAccountData: (input: { readonly userId: string }) => Promise<void>;
  readonly deleteIOSAnalyticsIdentities: (input: { readonly userId: string }) => Promise<void>;
  readonly deletePostHogPersonData: (
    userId: string,
    distinctIds: readonly string[],
  ) => Promise<void>;
  readonly listPostHogDeletionDistinctIds: (input: { readonly userId: string }) => Promise<readonly string[]>;
  readonly loadStackUser: (userId: string) => Promise<StackAccountDeletionUser | null>;
  readonly markAccountDeletionCompleted: (input: { readonly userId: string }) => Promise<void>;
  readonly markAccountDeletionFailed: (
    input: { readonly userId: string; readonly error: unknown },
  ) => Promise<void>;
  readonly markAccountDeletionStackDeletePending: (
    input: { readonly userId: string; readonly error?: unknown },
  ) => Promise<void>;
  readonly listPendingAccountDeletionJobs: (
    input?: { readonly limit?: number },
  ) => Promise<readonly AccountDeletionJob[]>;
};

const defaultAccountDeletionProcessorDependencies: AccountDeletionProcessorDependencies = {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  deleteIOSAnalyticsIdentities,
  deletePostHogPersonData,
  listPostHogDeletionDistinctIds,
  loadStackUser: async (userId) =>
    await getStackServerApp().getUser(userId) as StackAccountDeletionUser | null,
  markAccountDeletionCompleted,
  markAccountDeletionFailed,
  markAccountDeletionStackDeletePending,
  listPendingAccountDeletionJobs,
};

export async function processAccountDeletionForUser(
  input: { readonly userId: string },
  dependencies: AccountDeletionProcessorDependencies = defaultAccountDeletionProcessorDependencies,
): Promise<"processed" | "skipped"> {
  const claimedStatus = await dependencies.claimAccountDeletionProcessing({ userId: input.userId });
  if (!claimedStatus) return "skipped";

  let stackDeletePending = claimedStatus === "stack_delete_pending";
  try {
    const user = await dependencies.loadStackUser(input.userId);
    if (!stackDeletePending) {
      await dependencies.deleteCmuxAccountData({ userId: input.userId });
      const postHogDistinctIds = await dependencies.listPostHogDeletionDistinctIds({ userId: input.userId });
      await dependencies.deletePostHogPersonData(input.userId, postHogDistinctIds);
      await dependencies.deleteIOSAnalyticsIdentities({ userId: input.userId });
      await dependencies.markAccountDeletionStackDeletePending({ userId: input.userId });
      stackDeletePending = true;
    }
    if (user) await user.delete();
    await dependencies.markAccountDeletionCompleted({ userId: input.userId });
    return "processed";
  } catch (error) {
    if (stackDeletePending) {
      await dependencies.markAccountDeletionStackDeletePending({ userId: input.userId, error });
    } else {
      await dependencies.markAccountDeletionFailed({ userId: input.userId, error });
    }
    throw error;
  }
}

export async function processPendingAccountDeletions(
  input: { readonly limit?: number } = {},
  dependencies: AccountDeletionProcessorDependencies = defaultAccountDeletionProcessorDependencies,
): Promise<{ readonly scanned: number; readonly processed: number; readonly skipped: number; readonly failed: number }> {
  const jobs = await dependencies.listPendingAccountDeletionJobs({ limit: input.limit });
  let processed = 0;
  let skipped = 0;
  let failed = 0;

  for (const job of jobs) {
    try {
      const result = await processAccountDeletionForUser({ userId: job.userId }, dependencies);
      if (result === "processed") processed += 1;
      else skipped += 1;
    } catch (error) {
      failed += 1;
      console.error("[account-deletion] job failed", { userIdHash: job.userIdHash, error });
    }
  }

  return { scanned: jobs.length, processed, skipped, failed };
}
