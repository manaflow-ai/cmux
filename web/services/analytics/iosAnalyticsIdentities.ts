import { eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { iosAnalyticsIdentities } from "../../db/schema";

const MAX_ANALYTICS_DISTINCT_ID_LENGTH = 512;
const MAX_IOS_ANALYTICS_IDENTITIES_PER_REQUEST = 16;
const MAX_IOS_ANALYTICS_IDENTITIES_PER_USER = 1024;
const IOS_INSTALL_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type IOSAnalyticsIdentityRuntime = {
  readonly cloudDb: typeof cloudDb;
};

type IOSAnalyticsIdentityDb = Pick<ReturnType<typeof cloudDb>, "delete" | "insert" | "select">;

const defaultIOSAnalyticsIdentityRuntime: IOSAnalyticsIdentityRuntime = {
  cloudDb,
};

export async function recordIOSAnalyticsIdentities(
  input: {
    readonly userId: string;
    readonly anonymousIds: readonly string[];
  },
  runtime: IOSAnalyticsIdentityRuntime = defaultIOSAnalyticsIdentityRuntime,
): Promise<readonly string[]> {
  return await runtime.cloudDb().transaction(async (tx) =>
    recordIOSAnalyticsIdentitiesInTransaction(input, tx)
  );
}

export async function recordIOSAnalyticsIdentitiesInTransaction(
  input: {
    readonly userId: string;
    readonly anonymousIds: readonly string[];
  },
  db: IOSAnalyticsIdentityDb,
): Promise<readonly string[]> {
  const anonymousIds = normalizedDistinctIds(input.anonymousIds)
    .filter((id) => id !== input.userId)
    .slice(0, MAX_IOS_ANALYTICS_IDENTITIES_PER_REQUEST);
  if (anonymousIds.length === 0) return [];

  const existingAnonymousIds = new Set(
    await listIOSAnalyticsAnonymousIdsForUser(db, input.userId, MAX_IOS_ANALYTICS_IDENTITIES_PER_USER + 1),
  );
  let remainingNewAliases = Math.max(0, MAX_IOS_ANALYTICS_IDENTITIES_PER_USER - existingAnonymousIds.size);
  const acceptedAnonymousIds: string[] = [];
  for (const anonymousId of anonymousIds) {
    if (existingAnonymousIds.has(anonymousId)) {
      acceptedAnonymousIds.push(anonymousId);
      continue;
    }
    if (remainingNewAliases <= 0) continue;
    existingAnonymousIds.add(anonymousId);
    remainingNewAliases -= 1;
    acceptedAnonymousIds.push(anonymousId);
  }
  if (acceptedAnonymousIds.length === 0) return [];

  const now = new Date();
  await db
    .insert(iosAnalyticsIdentities)
    .values(acceptedAnonymousIds.map((anonymousId) => ({
      userId: input.userId,
      anonymousId,
      createdAt: now,
      updatedAt: now,
    })))
    .onConflictDoUpdate({
      target: [iosAnalyticsIdentities.userId, iosAnalyticsIdentities.anonymousId],
      set: { updatedAt: now },
  });
  return acceptedAnonymousIds;
}

export async function listPostHogDeletionDistinctIds(
  input: { readonly userId: string },
  runtime: IOSAnalyticsIdentityRuntime = defaultIOSAnalyticsIdentityRuntime,
): Promise<readonly string[]> {
  const rows = await runtime.cloudDb()
    .select({ anonymousId: iosAnalyticsIdentities.anonymousId })
    .from(iosAnalyticsIdentities)
    .where(eq(iosAnalyticsIdentities.userId, input.userId));
  return Array.from(new Set([
    input.userId,
    ...normalizedDistinctIds(rows.map((row) => row.anonymousId)),
  ]));
}

export async function deleteIOSAnalyticsIdentities(
  input: { readonly userId: string },
  runtime: IOSAnalyticsIdentityRuntime = defaultIOSAnalyticsIdentityRuntime,
): Promise<void> {
  await runtime.cloudDb()
    .delete(iosAnalyticsIdentities)
    .where(eq(iosAnalyticsIdentities.userId, input.userId));
}

function normalizedDistinctIds(values: readonly string[]): string[] {
  return Array.from(new Set(values.map(normalizedDistinctId).filter((id): id is string => !!id)));
}

function normalizedDistinctId(value: string): string | null {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_ANALYTICS_DISTINCT_ID_LENGTH) return null;
  if (!IOS_INSTALL_ID_PATTERN.test(trimmed)) return null;
  return trimmed;
}

async function listIOSAnalyticsAnonymousIdsForUser(
  db: IOSAnalyticsIdentityDb,
  userId: string,
  limit: number,
): Promise<string[]> {
  const rows = await db
    .select({ anonymousId: iosAnalyticsIdentities.anonymousId })
    .from(iosAnalyticsIdentities)
    .where(eq(iosAnalyticsIdentities.userId, userId))
    .limit(limit);
  return rows.map((row) => row.anonymousId);
}
