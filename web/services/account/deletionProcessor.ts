import { getStackServerApp } from "../../app/lib/stack";
import {
  deleteIOSAnalyticsIdentities,
  listPostHogDeletionDistinctIds,
} from "../analytics/iosAnalyticsIdentities";
import { deletePostHogPersonData } from "../analytics/posthogDeletion";
import {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  hasAccountDeletionTombstone,
  isAccountDeletionTombstoneStoreConfigured,
  isStackAccountDeletionInProgress,
  listPendingAccountDeletionJobs,
  markAccountDeletionCompleted,
  markAccountDeletionFailed,
  markAccountDeletionRetryPending,
  markAccountDeletionStackDeletePending,
  AccountDeletionNonRetryableError,
  type AccountDeletionJob,
  type AccountDeletionStatus,
  type RetainedTeamBillingOwner,
  type StackAccountDeletionMetadataUser,
} from "./deletion";

export type StackAccountDeletionUser = StackAccountDeletionMetadataUser & {
  readonly id: string;
  readonly selectedTeam?: unknown;
  readonly listTeams?: (
    options?: { readonly cursor?: string; readonly limit?: number },
  ) => Promise<StackAccountDeletionPage>;
  delete(): Promise<void>;
};

type StackAccountDeletionTeam = {
  readonly id: string;
  readonly listUsers?: (
    options?: { readonly cursor?: string; readonly limit?: number },
  ) => Promise<StackAccountDeletionPage>;
};

type StackAccountDeletionMember = {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
};

type StackAccountDeletionPage = readonly unknown[] & {
  readonly nextCursor?: string | null;
};

export type AccountDeletionProcessorDependencies = {
  readonly claimAccountDeletionProcessing: (input: { readonly userId: string }) => Promise<AccountDeletionStatus | null>;
  readonly deleteCmuxAccountData: (
    input: {
      readonly userId: string;
      readonly ownedTeamIds?: readonly string[];
      readonly retainedTeamBillingOwners?: readonly RetainedTeamBillingOwner[];
    },
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

class AccountDeletionTeamScopeUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AccountDeletionTeamScopeUnavailableError";
  }
}

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
      if (!user) {
        throw new AccountDeletionTeamScopeUnavailableError("Stack account deletion team scope is unavailable.");
      }
      const teamScope = await accountDeletionTeamScopeForUser(user);
      await dependencies.deleteCmuxAccountData({
        userId: input.userId,
        ownedTeamIds: teamScope.ownedTeamIds,
        retainedTeamBillingOwners: teamScope.retainedTeamBillingOwners,
      });
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
    } else if (error instanceof AccountDeletionNonRetryableError) {
      await dependencies.markAccountDeletionFailed({ userId: input.userId, error });
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

export async function accountDeletionTeamScopeForUser(user: StackAccountDeletionUser): Promise<{
  readonly ownedTeamIds: readonly string[];
  readonly retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[];
}> {
  const listedTeams = await listAllAccountDeletionStackTeams(user);
  const teams = uniqueStackTeams([
    stackTeamFromUnknown(user.selectedTeam),
    ...listedTeams.map(stackTeamFromUnknown),
  ]);
  const ownedTeamIds: string[] = [];
  const retainedTeamBillingOwners: RetainedTeamBillingOwner[] = [];
  for (const team of teams) {
    const members = await accountDeletionTeamMembers(team);
    if (members.length === 1 && members[0]?.id === user.id) {
      ownedTeamIds.push(team.id);
      continue;
    }
    const retainedOwnerId = await retainedTeamBillingOwnerId(user.id, members);
    if (retainedOwnerId) {
      retainedTeamBillingOwners.push({ stackTeamId: team.id, stackUserId: retainedOwnerId });
    }
  }
  return { ownedTeamIds, retainedTeamBillingOwners };
}

async function retainedTeamBillingOwnerId(
  deletedUserId: string,
  members: readonly StackAccountDeletionMember[],
): Promise<string | null> {
  const candidates = members
    .filter((member) => member.id !== deletedUserId)
    .sort((left, right) => left.id.localeCompare(right.id));
  for (const member of candidates) {
    if (isStackAccountDeletionInProgress(member.clientReadOnlyMetadata)) continue;
    if (await hasBlockingAccountDeletionTombstoneForUser(member.id)) continue;
    return member.id;
  }
  return null;
}

async function hasBlockingAccountDeletionTombstoneForUser(userId: string): Promise<boolean> {
  if (!isAccountDeletionTombstoneStoreConfigured()) return false;
  return await hasAccountDeletionTombstone({ userId });
}

async function listAllAccountDeletionStackTeams(user: StackAccountDeletionUser): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") {
    throw new AccountDeletionTeamScopeUnavailableError("Stack account deletion team scope is unavailable.");
  }

  const teams: unknown[] = [];
  const seenCursors = new Set<string>();
  const limit = 100;
  let cursor: string | undefined;
  do {
    const page = await user.listTeams({ cursor, limit });
    teams.push(...Array.from(page));
    const nextCursor = normalizedStackCursor(page.nextCursor);
    if (!nextCursor) break;
    if (seenCursors.has(nextCursor)) {
      throw new AccountDeletionTeamScopeUnavailableError("Stack account deletion team pagination looped.");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  } while (true);
  return teams;
}

async function accountDeletionTeamMembers(team: StackAccountDeletionTeam): Promise<readonly StackAccountDeletionMember[]> {
  if (typeof team.listUsers !== "function") {
    throw new AccountDeletionTeamScopeUnavailableError(`Stack team ${team.id} member scope is unavailable.`);
  }

  const members: unknown[] = [];
  const seenCursors = new Set<string>();
  const limit = 100;
  let cursor: string | undefined;
  do {
    const page = await team.listUsers({ cursor, limit });
    members.push(...Array.from(page));
    const nextCursor = normalizedStackCursor(page.nextCursor);
    if (!nextCursor) break;
    if (seenCursors.has(nextCursor)) {
      throw new AccountDeletionTeamScopeUnavailableError(`Stack team ${team.id} member pagination looped.`);
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  } while (true);

  return uniqueStackTeamMembers(members.flatMap((member) => {
    if (!member || typeof member !== "object") return [];
    const id = (member as { readonly id?: unknown }).id;
    if (typeof id !== "string" || !id.trim()) return [];
    return [{
      id: id.trim(),
      clientReadOnlyMetadata: (member as { readonly clientReadOnlyMetadata?: unknown }).clientReadOnlyMetadata,
    }];
  }));
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
      ? async (options) => await listUsers.call(value, options)
      : undefined,
  };
}

function uniqueStackTeams(
  values: readonly (StackAccountDeletionTeam | null)[],
): readonly StackAccountDeletionTeam[] {
  const teams = new Map<string, StackAccountDeletionTeam>();
  for (const team of values) {
    if (!team) continue;
    const existing = teams.get(team.id);
    if (!existing || (typeof existing.listUsers !== "function" && typeof team.listUsers === "function")) {
      teams.set(team.id, team);
    }
  }
  return [...teams.values()];
}

function uniqueStrings(values: readonly string[]): readonly string[] {
  const strings: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    strings.push(value);
  }
  return strings;
}

function uniqueStackTeamMembers(
  values: readonly StackAccountDeletionMember[],
): readonly StackAccountDeletionMember[] {
  const members = new Map<string, StackAccountDeletionMember>();
  for (const member of values) {
    if (!members.has(member.id)) members.set(member.id, member);
  }
  return [...members.values()];
}
