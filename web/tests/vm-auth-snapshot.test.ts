import { beforeEach, describe, expect, mock, test } from "bun:test";

import type { AuthedUser } from "../services/vms/auth";

const getUser = mock(async (): Promise<unknown> => null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const snapshotState = {
  stored: null as { user: AuthedUser; ageMs: number } | null,
  writes: [] as { user: AuthedUser; completeTeamList: boolean }[],
  deletes: [] as string[],
};

mock.module("../services/auth/identitySnapshot", () => ({
  identitySnapshotTtlMs: () => 3_600_000,
  readIdentitySnapshot: async (_userId: string, maxAgeMs: number) =>
    snapshotState.stored && snapshotState.stored.ageMs <= maxAgeMs
      ? snapshotState.stored
      : null,
  writeIdentitySnapshot: async (
    user: AuthedUser,
    options: { completeTeamList: boolean },
  ) => {
    snapshotState.writes.push({ user, completeTeamList: options.completeTeamList });
  },
  deleteIdentitySnapshot: async (userId: string) => {
    snapshotState.deletes.push(userId);
  },
}));

const tombstoneState = { blocked: false };

mock.module("../services/account/deletionLock", () => ({
  accountDeletionUserHash: (userId: string) => `hash:${userId}`,
  isBlockingAccountDeletionTombstone: () => tombstoneState.blocked,
}));

mock.module("../db/client", () => ({
  cloudDb: () => ({
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => tombstoneState.blocked
            ? [{ userIdHash: "hash:jwt-user-1", status: "pending", updatedAt: new Date() }]
            : [],
        }),
      }),
    }),
  }),
  closeCloudDbForTests: async () => {},
}));

const { verifyRequestFromSnapshot, clearNativeAuthCacheForTests, clearStackThrottleCircuitForTests } =
  await import("../services/vms/auth");

const snapshotUser: AuthedUser = {
  id: "jwt-user-1",
  displayName: "Snapshot User",
  primaryEmail: "snapshot@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-a",
  selectedTeamId: "team-a",
  teams: [{ id: "team-a", displayName: "Team A", billingPlanId: "pro", billingSeats: 2 }],
  teamIds: ["team-a"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 2,
};

const stackUser = {
  id: "stack-user-1",
  displayName: "Stack User",
  primaryEmail: "stack@example.com",
  selectedTeam: { id: "team-a" },
  clientReadOnlyMetadata: {},
  listTeams: async () => [{ id: "team-a" }, { id: "team-b" }],
};

const localIdentity = async (token: string) => token === "good-token"
  ? {
    userId: "jwt-user-1",
    projectId: "project-1",
    refreshTokenId: "rt-1",
    isAnonymous: false,
    expiresAt: new Date(Date.now() + 3_000_000),
  }
  : null;

function nativeRequest(access: string): Request {
  return new Request("https://cmux.test/api/devices", {
    method: "POST",
    headers: {
      authorization: `Bearer ${access}`,
      "x-stack-refresh-token": "refresh-1",
    },
  });
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  clearStackThrottleCircuitForTests();
  getUser.mockClear();
  getUser.mockResolvedValue(stackUser);
  snapshotState.stored = null;
  snapshotState.writes = [];
  snapshotState.deletes = [];
  tombstoneState.blocked = false;
});

describe("verifyRequestFromSnapshot", () => {
  test("a locally verified token plus a fresh snapshot never calls Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 60_000 };
    const user = await verifyRequestFromSnapshot(nativeRequest("good-token"), {
      verifyAccessToken: localIdentity,
    });
    expect(user).toEqual(snapshotUser);
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("no snapshot falls back to Stack and stores the complete team list", async () => {
    const user = await verifyRequestFromSnapshot(nativeRequest("good-token"), {
      verifyAccessToken: localIdentity,
    });
    expect(user?.id).toBe("stack-user-1");
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(snapshotState.writes).toHaveLength(1);
    expect(snapshotState.writes[0]?.completeTeamList).toBe(true);
    expect(snapshotState.writes[0]?.user.teamIds).toEqual(["team-a", "team-b"]);
  });

  test("a token the local check rejects falls back to Stack even with a snapshot", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 60_000 };
    const user = await verifyRequestFromSnapshot(nativeRequest("stale-token"), {
      verifyAccessToken: localIdentity,
    });
    expect(user?.id).toBe("stack-user-1");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("a snapshot older than the max age falls back to Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 120_000 };
    const user = await verifyRequestFromSnapshot(nativeRequest("good-token"), {
      verifyAccessToken: localIdentity,
      maxSnapshotAgeMs: 60_000,
    });
    expect(user?.id).toBe("stack-user-1");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("a deleted account is refused on the snapshot path and its row dropped", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 1_000 };
    tombstoneState.blocked = true;
    const user = await verifyRequestFromSnapshot(nativeRequest("good-token"), {
      verifyAccessToken: localIdentity,
    });
    expect(user).toBeNull();
    expect(snapshotState.deletes).toEqual(["jwt-user-1"]);
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("a request with no native tokens never answers from a snapshot", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 1_000 };
    const user = await verifyRequestFromSnapshot(
      new Request("https://cmux.test/api/devices", { method: "POST" }),
      { verifyAccessToken: localIdentity },
    );
    expect(user).toBeNull();
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("the requested team id reaches the Stack fallback", async () => {
    await verifyRequestFromSnapshot(nativeRequest("stale-token"), {
      verifyAccessToken: localIdentity,
      requestedTeamId: "team-b",
    });
    const resolved = snapshotState.writes[0]?.user;
    expect(resolved?.teamIds).toContain("team-b");
  });
});
