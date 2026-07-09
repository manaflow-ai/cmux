import { getStackServerApp } from "../../app/lib/stack";
import { deletePostHogPersonData } from "../analytics/posthogDeletion";
import {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  listPendingAccountDeletionJobs,
  markAccountDeletionCompleted,
  markAccountDeletionFailed,
  type AccountDeletionJob,
  type StackAccountDeletionMetadataUser,
} from "./deletion";

type StackAccountDeletionUser = StackAccountDeletionMetadataUser & {
  readonly id: string;
  delete(): Promise<void>;
};

export type AccountDeletionProcessorDependencies = {
  readonly claimAccountDeletionProcessing: (input: { readonly userId: string }) => Promise<boolean>;
  readonly deleteCmuxAccountData: (input: { readonly userId: string }) => Promise<void>;
  readonly deletePostHogPersonData: (userId: string) => Promise<void>;
  readonly loadStackUser: (userId: string) => Promise<StackAccountDeletionUser | null>;
  readonly markAccountDeletionCompleted: (input: { readonly userId: string }) => Promise<void>;
  readonly markAccountDeletionFailed: (
    input: { readonly userId: string; readonly error: unknown },
  ) => Promise<void>;
  readonly listPendingAccountDeletionJobs: (
    input?: { readonly limit?: number },
  ) => Promise<readonly AccountDeletionJob[]>;
};

const defaultAccountDeletionProcessorDependencies: AccountDeletionProcessorDependencies = {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  deletePostHogPersonData,
  loadStackUser: async (userId) =>
    await getStackServerApp().getUser(userId) as StackAccountDeletionUser | null,
  markAccountDeletionCompleted,
  markAccountDeletionFailed,
  listPendingAccountDeletionJobs,
};

export async function processAccountDeletionForUser(
  input: { readonly userId: string },
  dependencies: AccountDeletionProcessorDependencies = defaultAccountDeletionProcessorDependencies,
): Promise<"processed" | "skipped"> {
  const claimed = await dependencies.claimAccountDeletionProcessing({ userId: input.userId });
  if (!claimed) return "skipped";

  try {
    const user = await dependencies.loadStackUser(input.userId);
    await dependencies.deleteCmuxAccountData({ userId: input.userId });
    await dependencies.deletePostHogPersonData(input.userId);
    await dependencies.markAccountDeletionCompleted({ userId: input.userId });
    if (user) await user.delete();
    return "processed";
  } catch (error) {
    await dependencies.markAccountDeletionFailed({ userId: input.userId, error });
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
