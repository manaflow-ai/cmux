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
  markAccountDeletionRetryPending,
  markAccountDeletionStackDeletePending,
  type AccountDeletionJob,
  type AccountDeletionStatus,
  type StackAccountDeletionMetadataUser,
} from "./deletion";

type StackAccountDeletionUser = StackAccountDeletionMetadataUser & {
  readonly id: string;
  readonly selectedTeam?: unknown;
  readonly listTeams?: (
    options?: { readonly cursor?: string; readonly limit?: number },
  ) => Promise<StackAccountDeletionTeamPage>;
  delete(): Promise<void>;
};

type StackAccountDeletionTeam = {
  readonly id: string;
  readonly listUsers?: () => Promise<readonly unknown[]>;
};

type StackAccountDeletionTeamPage = readonly unknown[] & {
  readonly nextCursor?: string | null;
};

export type AccountDeletionProcessorDependencies = {
  readonly claimAccountDeletionProcessing: (input: { readonly userId: string }) => Promise<AccountDeletionStatus | null>;
  readonly deleteCmuxAccountData: (
    input: { readonly userId: string; readonly ownedTeamIds?: readonly string[] },
  ) => Promise<void>;
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
  readonly markAccountDeletionRetryPending: (
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
  markAccountDeletionRetryPending,
  markAccountDeletionStackDeletePending,
  listPendingAccountDeletionJobs,
};

export async function processAccountDeletionForUser(
  input: { readonly userId: string },
  dependencies: AccountDeletionProcessorDependencies = defaultAccountDeletionProcessorDependencies,
): Promise<"processed" | "skipped"> {
  const claimedStatus = await dependencies.claimAccountDeletionProcessing({ userId: input.userId });
  if (!claimedStatus) return "skipped";

  let stackDeletePending =
    claimedStatus === "stack_delete_pending" || claimedStatus === "stack_delete_in_progress";
  try {
    const user = await dependencies.loadStackUser(input.userId);
    if (!stackDeletePending) {
      if (!user) throw new Error("Stack user unavailable for account deletion");
      const ownedTeamIds = user ? await accountDeletionOwnedTeamIds(user) : [];
      await dependencies.deleteCmuxAccountData({ userId: input.userId, ownedTeamIds });
      const postHogDistinctIds = await dependencies.listPostHogDeletionDistinctIds({ userId: input.userId });
      await dependencies.deletePostHogPersonData(input.userId, postHogDistinctIds);
      await dependencies.deleteIOSAnalyticsIdentities({ userId: input.userId });
      await dependencies.markAccountDeletionStackDeletePending({ userId: input.userId });
      stackDeletePending = true;
    }
    if (user) await user.delete();
    // If this write fails after Stack deletion, the catch below keeps the
    // tombstone in stack-delete state so retry skips cmux and PostHog cleanup.
    await dependencies.markAccountDeletionCompleted({ userId: input.userId });
    return "processed";
  } catch (error) {
    if (stackDeletePending) {
      await dependencies.markAccountDeletionStackDeletePending({ userId: input.userId, error });
    } else {
      await dependencies.markAccountDeletionRetryPending({ userId: input.userId, error });
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

async function accountDeletionOwnedTeamIds(user: StackAccountDeletionUser): Promise<readonly string[]> {
  const listedTeams = await listAllAccountDeletionStackTeams(user);
  const teams = uniqueStackTeams([
    stackTeamFromUnknown(user.selectedTeam),
    ...listedTeams.map(stackTeamFromUnknown),
  ]);
  const ownedTeamIds: string[] = [];
  for (const team of teams) {
    if (await isOnlyTeamMember(team, user.id)) ownedTeamIds.push(team.id);
  }
  return ownedTeamIds;
}

async function listAllAccountDeletionStackTeams(user: StackAccountDeletionUser): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") return [];

  const teams: unknown[] = [];
  const seenCursors = new Set<string>();
  let cursor: string | undefined;
  do {
    const page = await user.listTeams({ cursor, limit: 100 });
    teams.push(...Array.from(page));
    const nextCursor = normalizedStackCursor(page.nextCursor);
    if (!nextCursor || seenCursors.has(nextCursor)) break;
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  } while (true);
  return teams;
}

async function isOnlyTeamMember(team: StackAccountDeletionTeam, userId: string): Promise<boolean> {
  if (typeof team.listUsers !== "function") return false;
  const members = await team.listUsers();
  const memberIds = members.flatMap((member) => {
    if (!member || typeof member !== "object") return [];
    const id = (member as { readonly id?: unknown }).id;
    return typeof id === "string" && id.trim() ? [id.trim()] : [];
  });
  return memberIds.length === 1 && memberIds[0] === userId;
}

function normalizedStackCursor(value: string | null | undefined): string | undefined {
  const cursor = value?.trim();
  return cursor ? cursor : undefined;
}

function stackTeamFromUnknown(value: unknown): StackAccountDeletionTeam | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { readonly id?: unknown }).id;
  if (typeof id !== "string" || !id.trim()) return null;
  const listUsers = (value as { readonly listUsers?: unknown }).listUsers;
  return {
    id: id.trim(),
    listUsers: typeof listUsers === "function"
      ? async () => await listUsers.call(value)
      : undefined,
  };
}

function uniqueStackTeams(
  values: readonly (StackAccountDeletionTeam | null)[],
): readonly StackAccountDeletionTeam[] {
  const teams: StackAccountDeletionTeam[] = [];
  const seen = new Set<string>();
  for (const team of values) {
    if (!team || seen.has(team.id)) continue;
    seen.add(team.id);
    teams.push(team);
  }
  return teams;
}
