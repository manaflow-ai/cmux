import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";

// GET /api/coderouter/organizations runs Stack verification, the identity
// snapshot write, and the API-key permission lookups under one 10 s deadline.
// Production traces showed the handler idle for 6-11 s between the last Stack
// call of verification and the first permission lookup: the only await there
// is the best-effort snapshot upsert, which queues behind a saturated
// database pool. These cases pin that the catalog never waits on that write,
// stops Stack work once the deadline fires, and reports the 503.

const stackUser = {
  id: "user-1",
  isAnonymous: false,
  displayName: "User One",
  primaryEmail: "user@example.com",
  selectedTeam: { id: "team-a", displayName: "Team A", clientReadOnlyMetadata: {} },
  clientReadOnlyMetadata: {},
  listTeams: async () => [
    { id: "team-a", displayName: "Team A", clientReadOnlyMetadata: {} },
    { id: "team-b", displayName: "Team B", clientReadOnlyMetadata: {} },
    { id: "team-c", displayName: "Team C", clientReadOnlyMetadata: {} },
  ],
};

const state = {
  stallSnapshotWrite: false,
  stallServerUser: false,
  snapshotWrites: 0,
  serverUserFetches: 0,
  permissionLookups: 0,
};

const hasPermission = mock(async () => {
  state.permissionLookups += 1;
  return true;
});

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getUser: async (arg: unknown) => {
      if (typeof arg !== "string") return stackUser;
      state.serverUserFetches += 1;
      if (state.stallServerUser) return new Promise(() => {});
      return { id: arg, hasPermission };
    },
    getTeam: async (id: string) => ({ id }),
  }),
}));

mock.module("../services/auth/identitySnapshot", () => ({
  identitySnapshotTtlMs: () => 600_000,
  readIdentitySnapshot: async () => null,
  deleteIdentitySnapshot: async () => {},
  writeIdentitySnapshot: (_user: unknown, options: { completeTeamList: boolean }) => {
    if (!options.completeTeamList) return Promise.resolve();
    state.snapshotWrites += 1;
    // A saturated pool: the upsert never gets a connection.
    return state.stallSnapshotWrite ? new Promise(() => {}) : Promise.resolve();
  },
}));

const { organizationsGet } = await import("../app/api/subrouter/teams/route");
const { authorizedCoderouterTeams } = await import("../services/coderouter/permissions");
const { clearNativeAuthCacheForTests } = await import("../services/vms/auth");

const originalTimeout = process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS;

function organizationsRequest(): Request {
  return new Request("https://coderouter.test/api/coderouter/organizations", {
    headers: {
      authorization: "Bearer access-1",
      "x-stack-refresh-token": "refresh-1",
    },
  });
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  state.stallSnapshotWrite = false;
  state.stallServerUser = false;
  state.snapshotWrites = 0;
  state.serverUserFetches = 0;
  state.permissionLookups = 0;
  hasPermission.mockClear();
  process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "300";
});

afterEach(() => {
  if (originalTimeout === undefined) delete process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS;
  else process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = originalTimeout;
});

describe("GET /api/coderouter/organizations deadline", () => {
  test("a stalled identity snapshot write does not hold the catalog past its deadline", async () => {
    state.stallSnapshotWrite = true;
    const response = await organizationsGet(organizationsRequest(), authorizedCoderouterTeams);
    expect(response.status).toBe(200);
    const body = await response.json() as { teams: { id: string }[] };
    expect(body.teams.map((team) => team.id)).toEqual(["team-a", "team-b", "team-c", "user-1"]);
    // The snapshot is still refreshed; it just is not on the response path.
    expect(state.snapshotWrites).toBe(1);
  });

  test("permission lookups fetch the Stack user once for every team", async () => {
    const response = await organizationsGet(organizationsRequest(), authorizedCoderouterTeams);
    expect(response.status).toBe(200);
    expect(state.serverUserFetches).toBe(1);
    expect(state.permissionLookups).toBe(3);
  });

  test("a deadline during permission lookups reports the 503 and starts no more Stack calls", async () => {
    state.stallServerUser = true;
    const consoleError = spyOn(console, "error").mockImplementation(() => {});
    try {
      const response = await organizationsGet(organizationsRequest(), authorizedCoderouterTeams);
      expect(response.status).toBe(503);
      expect(consoleError.mock.calls.some((call) => call[0] === "cmux.observability.error")).toBe(true);
    } finally {
      consoleError.mockRestore();
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(state.permissionLookups).toBe(0);
  });
});
