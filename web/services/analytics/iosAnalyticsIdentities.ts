import { eq, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { iosAnalyticsIdentities } from "../../db/schema";

const MAX_ANALYTICS_DISTINCT_ID_LENGTH = 512;
const MAX_IOS_ANALYTICS_IDENTITIES_PER_USER = 16;
const IOS_INSTALL_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type IOSAnalyticsIdentityRuntime = {
  readonly cloudDb: typeof cloudDb;
};

const defaultIOSAnalyticsIdentityRuntime: IOSAnalyticsIdentityRuntime = {
  cloudDb,
};

export async function recordIOSAnalyticsIdentities(
  input: {
    readonly userId: string;
    readonly anonymousIds: readonly string[];
  },
  runtime: IOSAnalyticsIdentityRuntime = defaultIOSAnalyticsIdentityRuntime,
): Promise<void> {
  const anonymousIds = normalizedDistinctIds(input.anonymousIds)
    .filter((id) => id !== input.userId)
    .slice(0, MAX_IOS_ANALYTICS_IDENTITIES_PER_USER);
  if (anonymousIds.length === 0) return;

  const now = new Date();
  await runtime.cloudDb().transaction(async (tx) => {
    await tx
      .insert(iosAnalyticsIdentities)
      .values(anonymousIds.map((anonymousId) => ({
        userId: input.userId,
        anonymousId,
        createdAt: now,
        updatedAt: now,
      })))
      .onConflictDoUpdate({
        target: [iosAnalyticsIdentities.userId, iosAnalyticsIdentities.anonymousId],
        set: { updatedAt: now },
      });

    await tx.execute(sql`
      delete from ${iosAnalyticsIdentities}
      where ${iosAnalyticsIdentities.userId} = ${input.userId}
        and ${iosAnalyticsIdentities.anonymousId} not in (
          select ${iosAnalyticsIdentities.anonymousId}
          from ${iosAnalyticsIdentities}
          where ${iosAnalyticsIdentities.userId} = ${input.userId}
          order by ${iosAnalyticsIdentities.updatedAt} desc, ${iosAnalyticsIdentities.anonymousId} desc
          limit ${MAX_IOS_ANALYTICS_IDENTITIES_PER_USER}
        )
    `);
  });
}

export async function listPostHogDeletionDistinctIds(
  input: { readonly userId: string },
  runtime: IOSAnalyticsIdentityRuntime = defaultIOSAnalyticsIdentityRuntime,
): Promise<readonly string[]> {
  const rows = await runtime.cloudDb()
    .select({ anonymousId: iosAnalyticsIdentities.anonymousId })
    .from(iosAnalyticsIdentities)
    .where(eq(iosAnalyticsIdentities.userId, input.userId))
    .limit(MAX_IOS_ANALYTICS_IDENTITIES_PER_USER);
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
