import { beforeEach, describe, expect, mock, test } from "bun:test";

import type { AuthedUser } from "../services/vms/auth";

// The four highest-volume Stack callers in production (Axiom, 2026-10-12) are
// read-only polls from the Mac app: GET /api/vm, GET /api/vm/[id]/stats,
// GET /api/coderouter/organizations and GET /api/coderouter/vm-usage/team.
// Together they made ~1.2M of ~1.43M Stack calls a day, one or two per poll.
// These cases pin that a poll with a locally verifiable access token and a
// fresh identity snapshot makes no Stack call, and that everything the
// snapshot cannot answer still goes to Stack.

const stackUser = {
  id: "user-1",
  isAnonymous: false,
  displayName: "Stack User",
  primaryEmail: "stack@example.com",
  selectedTeam: { id: "team-a", displayName: "Team A", clientReadOnlyMetadata: {} },
  clientReadOnlyMetadata: {},
  listTeams: async () => Object.assign(
    [
      { id: "team-a", displayName: "Team A", clientReadOnlyMetadata: {} },
      { id: "team-b", displayName: "Team B", clientReadOnlyMetadata: {} },
    ],
    { nextCursor: null },
  ),
};

const getUser = mock(async (_arg?: unknown): Promise<unknown> => stackUser);

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
  identitySnapshotTtlMs: () => 600_000,
  readIdentitySnapshot: async (userId: string, maxAgeMs: number) =>
    snapshotState.stored &&
      snapshotState.stored.user.id === userId &&
      snapshotState.stored.ageMs <= maxAgeMs
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

// Local access-token verification: "good-token" is a valid Stack JWT for
// user-1; anything else is not locally verifiable.
mock.module("../services/auth/stackAccessToken", () => ({
  stackAccessTokenVerifierFromEnv: () => ({ issuer: "test", audience: "test" }),
  verifyStackAccessTokenLocally: async (token: string) => token === "good-token"
    ? {
      userId: "user-1",
      projectId: "project-1",
      refreshTokenId: "rt-1",
      isAnonymous: false,
      expiresAt: new Date(Date.now() + 3_000_000),
    }
    : null,
}));

// The account-deletion tombstone read: no tombstones in these cases.
const tombstoneRows: unknown[] = [];
const emptySelect = {
  from: () => emptySelect,
  where: () => emptySelect,
  limit: async () => tombstoneRows,
};
mock.module("../db/client", () => ({
  cloudDb: () => ({ select: () => emptySelect }),
  preconnectCloudDb: async () => {},
}));

const { withAuthedVmApiRoute } = await import("../services/vms/routeHelpers");
const { resolveCoderouterUsageTeam } = await import("../services/coderouter/requestContext");
const { organizationsGet } = await import("../app/api/subrouter/teams/route");
const { clearNativeAuthCacheForTests, clearStackThrottleCircuitForTests } =
  await import("../services/vms/auth");

const snapshotUser: AuthedUser = {
  id: "user-1",
  displayName: "Snapshot User",
  primaryEmail: "snapshot@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-a",
  selectedTeamId: "team-a",
  teams: [
    { id: "team-a", displayName: "Team A", billingPlanId: "pro", billingSeats: 2 },
    { id: "team-c", displayName: "Team C", billingPlanId: null, billingSeats: null },
  ],
  teamIds: ["team-a", "team-c"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 2,
};

function nativeRequest(
  url: string,
  access = "good-token",
  init: { method?: string; headers?: Record<string, string> } = {},
): Request {
  return new Request(url, {
    method: init.method ?? "GET",
    headers: {
      authorization: `Bearer ${access}`,
      "x-stack-refresh-token": "refresh-1",
      ...init.headers,
    },
  });
}

async function vmRouteUser(
  request: Request,
  route: string,
  operation: string,
): Promise<{ status: number; user: AuthedUser | null }> {
  let seen: AuthedUser | null = null;
  const response = await withAuthedVmApiRoute(
    request,
    route,
    { "cmux.vm.operation": operation },
    `${route} failed`,
    async ({ user }) => {
      seen = user;
      return new Response("{}", { status: 200 });
    },
  );
  return { status: response.status, user: seen };
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  clearStackThrottleCircuitForTests();
  getUser.mockClear();
  snapshotState.stored = null;
  snapshotState.writes = [];
  snapshotState.deletes = [];
});

describe("polled VM reads", () => {
  test("GET /api/vm answers from a fresh snapshot without calling Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const result = await vmRouteUser(nativeRequest("https://cmux.test/api/vm"), "/api/vm", "list");
    expect(result.status).toBe(200);
    expect(result.user?.teamIds).toEqual(["team-a", "team-c"]);
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("GET /api/vm/[id]/stats answers from a fresh snapshot without calling Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const result = await vmRouteUser(
      nativeRequest("https://cmux.test/api/vm/vm-1/stats"),
      "/api/vm/[id]/stats",
      "stats",
    );
    expect(result.status).toBe(200);
    expect(result.user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("a snapshot miss asks Stack once and stores a complete team list for the next poll", async () => {
    const first = await vmRouteUser(nativeRequest("https://cmux.test/api/vm"), "/api/vm", "list");
    expect(first.status).toBe(200);
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(snapshotState.writes).toHaveLength(1);
    expect(snapshotState.writes[0]?.completeTeamList).toBe(true);
    expect(snapshotState.writes[0]?.user.teamIds).toEqual(["team-a", "team-b"]);
  });

  test("a requested team the snapshot does not list is checked with Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const result = await vmRouteUser(
      nativeRequest("https://cmux.test/api/vm?teamId=team-b"),
      "/api/vm",
      "list",
    );
    expect(result.status).toBe(200);
    expect(result.user?.teamIds).toContain("team-b");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("a token that is not locally verifiable is checked with Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const result = await vmRouteUser(
      nativeRequest("https://cmux.test/api/vm", "expired-token"),
      "/api/vm",
      "list",
    );
    expect(result.status).toBe(200);
    expect(result.user?.displayName).toBe("Stack User");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("VM mutations never answer from the snapshot", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    await vmRouteUser(
      nativeRequest("https://cmux.test/api/vm/vm-1", "good-token", { method: "DELETE" }),
      "/api/vm/[id]",
      "destroy",
    );
    expect(getUser).toHaveBeenCalledTimes(1);
  });
});

describe("polled coderouter reads", () => {
  test("vm-usage team resolution answers from a fresh snapshot without calling Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const resolved = await resolveCoderouterUsageTeam(
      nativeRequest("https://cmux.test/api/coderouter/vm-usage/team"),
      { readOnly: true },
    );
    expect(resolved).toMatchObject({ ok: true, teamId: "team-a", stackUserId: "user-1" });
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("the organization catalog answers from a fresh snapshot without calling Stack", async () => {
    snapshotState.stored = { user: snapshotUser, ageMs: 30_000 };
    const response = await organizationsGet(
      nativeRequest("https://cmux.test/api/coderouter/organizations"),
    );
    expect(response.status).toBe(200);
    const body = await response.json() as { selectedTeamId: string; teams: { id: string }[] };
    expect(body.selectedTeamId).toBe("team-a");
    expect(body.teams.map((team) => team.id)).toEqual(["team-a", "team-c", "user-1"]);
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("an organization catalog miss lists every team and refreshes the snapshot", async () => {
    const response = await organizationsGet(
      nativeRequest("https://cmux.test/api/coderouter/organizations"),
    );
    expect(response.status).toBe(200);
    expect(getUser).toHaveBeenCalledTimes(1);
    // The deadline-gated path defers the write past the response.
    await new Promise((resolve) => setImmediate(resolve));
    expect(snapshotState.writes.some((write) => write.completeTeamList)).toBe(true);
  });
});
