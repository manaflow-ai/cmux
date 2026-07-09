import { describe, expect, test } from "bun:test";
import {
  listPostHogDeletionDistinctIds,
  recordIOSAnalyticsIdentities,
  type IOSAnalyticsIdentityRuntime,
} from "../services/analytics/iosAnalyticsIdentities";

describe("iOS analytics identities", () => {
  test("caps per-request identity writes without evicting deletion aliases", async () => {
    const { identities, runtime } = identityRuntime();

    const recorded = await recordIOSAnalyticsIdentities({
      userId: "stack-user-1",
      anonymousIds: [
        "stack-user-1",
        ...Array.from({ length: 25 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`),
      ],
    }, runtime);

    expect(identities.map((row) => row.anonymousId)).toEqual(
      Array.from({ length: 16 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`),
    );
    expect(recorded).toEqual(
      Array.from({ length: 16 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`),
    );
  });

  test("retains older aliases for account deletion", async () => {
    const userId = "stack-user-1";
    const { identities, runtime } = identityRuntime(
      Array.from({ length: 64 }, (_, index) => ({
        userId,
        anonymousId: analyticsId(index),
        createdAt: new Date(0),
        updatedAt: new Date(0),
      })),
    );
    const newAnonymousIds = Array.from({ length: 16 }, (_, index) => analyticsId(index + 100));

    await recordIOSAnalyticsIdentities({ userId, anonymousIds: newAnonymousIds }, runtime);
    const deletionDistinctIds = await listPostHogDeletionDistinctIds({ userId }, runtime);

    const userAnonymousIds = identities
      .filter((row) => row.userId === userId)
      .map((row) => row.anonymousId);
    expect(userAnonymousIds).toHaveLength(80);
    expect(newAnonymousIds.every((anonymousId) => userAnonymousIds.includes(anonymousId))).toBe(true);
    expect(deletionDistinctIds).toEqual([userId, ...userAnonymousIds]);
  });
});

type StoredIdentity = {
  readonly userId: string;
  readonly anonymousId: string;
  readonly createdAt: Date;
  updatedAt: Date;
};

function identityRuntime(initialIdentities: StoredIdentity[] = []) {
  const identities = [...initialIdentities];
  const runtime = {
    cloudDb: () => ({
      transaction: async <T>(fn: (tx: unknown) => Promise<T>) => {
        return await fn({
          insert: () => ({
            values: (values: StoredIdentity[]) => ({
              onConflictDoUpdate: async () => {
                for (const value of values) {
                  const existing = identities.find((row) =>
                    row.userId === value.userId && row.anonymousId === value.anonymousId
                  );
                  if (existing) existing.updatedAt = value.updatedAt;
                  else identities.push({ ...value });
                }
              },
            }),
          }),
        });
      },
      select: () => ({
        from: () => ({
          where: async () => identities.map((row) => ({ anonymousId: row.anonymousId })),
        }),
      }),
    }),
  } as unknown as IOSAnalyticsIdentityRuntime;
  return { identities, runtime };
}

function analyticsId(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}
