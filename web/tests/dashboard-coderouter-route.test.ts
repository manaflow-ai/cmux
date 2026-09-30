import { beforeEach, describe, expect, mock, test } from "bun:test";

const authorizationFailure = new Error("Stack authorization deadline exceeded");
let stackConfigured = true;
let authorizationAvailable = true;
let signedIn = true;
let authJsonAvailable = true;
let cutoverReady = true;
let hostedControlConfigured = true;
let hostedExchangeCalls = 0;
let selectedTeamId: string | null = "team-1";
let authorizationCalls = 0;
let machineMetricsKind: "ready" | "unavailable" = "ready";
let authorizedTeams: Array<{
  teamId: string;
  teamName: string;
  use: boolean;
  manageAccounts: boolean;
  manageApiKeys?: boolean;
  personal?: boolean;
}> = [];
const metricsTeamIds: string[] = [];
const machineMetricsCalls: Array<[string, string]> = [];
const verifyOptions: unknown[] = [];

mock.module("next/server", () => ({
  connection: async () => undefined,
  after: (task: () => unknown) => {
    void task;
  },
}));

mock.module("next/cache", () => ({
  cacheLife: () => undefined,
  unstable_cache: <T extends (...args: never[]) => unknown>(fn: T) => fn,
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => stackConfigured,
  getStackServerApp: () => ({
    getAuthJson: async () => {
      if (!authJsonAvailable) throw new Error("Stack refresh unavailable");
      return { accessToken: "test-access-token" };
    },
  }),
}));

class TestSubrouterAuthorizationUnavailableError extends Error {}

// The route's JSON helper imports the rest of the auth module, so only the
// dashboard authorization entrypoints are replaced.
const realAuth = { ...await import("../services/vms/auth") };
mock.module("../services/vms/auth", () => ({
  ...realAuth,
  withSubrouterAuthorizationDeadline: async (
    operation: (signal: AbortSignal) => Promise<unknown>,
  ) => {
    if (!authorizationAvailable) throw authorizationFailure;
    return await operation(new AbortController().signal);
  },
  verifySubrouterRequest: async (_request: Request, _signal: AbortSignal, options: unknown) => {
    authorizationCalls += 1;
    verifyOptions.push(options);
    return signedIn ? { id: "user-1", selectedTeamId } : null;
  },
  SubrouterAuthorizationUnavailableError: TestSubrouterAuthorizationUnavailableError,
  isSubrouterAuthorizationError: (error: unknown) =>
    error === authorizationFailure || error instanceof TestSubrouterAuthorizationUnavailableError,
}));

mock.module("../services/coderouter/permissions", () => ({
  authorizedCoderouterTeams: async () =>
    authorizedTeams.map((team) => ({
      manageApiKeys: false,
      personal: false,
      ...team,
    })),
}));

mock.module("../services/subrouter/hostedClient", () => ({
  createHostedSubrouterClient: () => ({
    tenantControlConfigured: hostedControlConfigured,
    exchangeTeam: async () => {
      hostedExchangeCalls += 1;
      return { tenantId: "team-1", tenantKey: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    },
    listAccounts: async () => [{
      id: "shared-1",
      kind: "codex",
      label: "shared codex",
      createdAt: "2026-08-20T00:00:00.000Z",
      health: { ok: true },
      // The hosted response can carry more than the dashboard shows.
      credential: "srt-secret-credential",
    }],
  }),
}));

mock.module("../services/subrouter/cutover", () => ({
  hostedSubrouterCutoverReadyForTeam: async () => cutoverReady,
}));

mock.module("../services/coderouter/teamMetrics", () => ({
  loadCoderouterTeamMetrics: async (teamId: string) => {
    metricsTeamIds.push(teamId);
    return {
      kind: "ready",
      periodDays: 30,
      generatedAt: "2026-08-08T12:00:00.000Z",
      rateCardVersion: "2026-08-08",
      totals: {
        inputTokens: 1_000,
        cachedInputTokens: 200,
        outputTokens: 300,
        totalTokens: 1_300,
        apiEquivalentUsd: 4.25,
        pricedTokens: 1_300,
        unpricedTokens: 0,
      },
      daily: [{ day: "2026-08-08", totalTokens: 1_300, apiEquivalentUsd: 4.25 }],
    };
  },
}));

mock.module("../db/client", () => ({ cloudDb: () => ({}) }));

mock.module("../services/coderouter/vmMetrics", () => ({
  loadCoderouterTeamMachineMetrics: async (teamId: string, surface: string) => {
    machineMetricsCalls.push([teamId, surface]);
    if (machineMetricsKind === "unavailable") return { kind: "unavailable" };
    const totals = (totalTokens: number, apiEquivalentUsd: number) => ({
      inputTokens: totalTokens,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens,
      apiEquivalentUsd,
      pricedTokens: totalTokens,
      unpricedTokens: 0,
    });
    return {
      kind: "ready",
      periodDays: 30,
      generatedAt: "2026-08-08T12:00:00.000Z",
      rateCardVersion: "2026-08-08",
      machines: [
        { vmId: "0f4b1c2e-1111-4222-8333-444455556666", totals: totals(1_000, 2.5) },
        { vmId: "not-owned-by-this-team", totals: totals(2, 0.01) },
      ],
    };
  },
}));

mock.module("../services/coderouter/teamMachines", () => ({
  listTeamMachines: async () => [{
    vmId: "0f4b1c2e-1111-4222-8333-444455556666",
    displayName: "builder-01",
    destroyed: false,
    createdAt: "2026-08-01T00:00:00.000Z",
  }],
  findTeamMachine: async () => null,
  normalizeVmId: (value: string) => value,
}));

mock.module("../services/coderouter/claudeUpstream", () => ({
  listClaudeAccounts: async () => [],
}));

mock.module("../services/coderouter/repository", () => ({
  listAccounts: async () => [],
}));

const { GET } = await import("../app/api/dashboard/coderouter/route");

async function get(team?: string) {
  const url = new URL("https://cmux.test/api/dashboard/coderouter");
  if (team) url.searchParams.set("team", team);
  const response = await GET(new Request(url, { headers: { cookie: "stack-refresh=1" } }));
  const text = await response.text();
  return { response, text, body: JSON.parse(text) as Record<string, unknown> };
}

const twoTeams = () => [
  { teamId: "team-1", teamName: "Team One", use: true, manageAccounts: true },
  { teamId: "team-2", teamName: "Team Two", use: true, manageAccounts: true },
];

describe("GET /api/dashboard/coderouter", () => {
  beforeEach(() => {
    stackConfigured = true;
    authorizationAvailable = true;
    signedIn = true;
    authJsonAvailable = true;
    cutoverReady = true;
    hostedControlConfigured = true;
    hostedExchangeCalls = 0;
    selectedTeamId = "team-1";
    authorizationCalls = 0;
    machineMetricsKind = "ready";
    metricsTeamIds.length = 0;
    machineMetricsCalls.length = 0;
    verifyOptions.length = 0;
    authorizedTeams = [{ teamId: "team-1", teamName: "Team One", use: true, manageAccounts: true, manageApiKeys: true }];
  });

  test("returns the selected team's overview without tokens or tenant keys", async () => {
    const { response, text, body } = await get("team-1");

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(verifyOptions).toEqual([{ allowCookie: true, listAllTeams: true }]);
    expect(body.selectedTeam).toEqual({
      id: "team-1",
      name: "Team One",
      use: true,
      manageAccounts: true,
      manageApiKeys: true,
      personal: false,
    });
    expect(body.viewerUserId).toBe("user-1");
    expect(body.claude).toEqual({ kind: "ok", accounts: [] });
    expect(body.native).toEqual({ kind: "ok", accounts: [] });
    expect(body.shared).toEqual({
      kind: "ok",
      accounts: [{
        id: "shared-1",
        kind: "codex",
        label: "shared codex",
        createdAt: "2026-08-20T00:00:00.000Z",
        health: { ok: true },
      }],
    });
    expect(metricsTeamIds).toEqual(["team-1"]);
    expect((body.metrics as { kind: string }).kind).toBe("ready");
    expect(text).not.toContain("test-access-token");
    expect(text).not.toContain("srt_");
    expect(text).not.toContain("srt-secret-credential");
  });

  test("answers 401 when the request is signed out", async () => {
    signedIn = false;
    const { response, body } = await get();
    expect(response.status).toBe(401);
    expect(body).toEqual({ error: { code: "unauthorized" } });
  });

  test("answers 503 when Stack authorization is unavailable", async () => {
    authorizationAvailable = false;
    const { response, body } = await get();
    expect(response.status).toBe(503);
    expect(body).toEqual({ error: { code: "authorization_unavailable" } });
  });

  test("answers 503 when the bounded Stack session refresh fails", async () => {
    authJsonAvailable = false;
    const { response } = await get();
    expect(response.status).toBe(503);
    expect(hostedExchangeCalls).toBe(0);
  });

  test("answers 409 no_teams when no team grants coderouter access", async () => {
    authorizedTeams = [{ teamId: "team-1", teamName: "Team One", use: false, manageAccounts: false }];
    const { response, body } = await get();
    expect(response.status).toBe(409);
    expect(body).toEqual({ error: { code: "no_teams" } });
    expect(metricsTeamIds).toEqual([]);
  });

  test("answers 404 when Stack is not configured", async () => {
    stackConfigured = false;
    const { response } = await get();
    expect(response.status).toBe(404);
    expect(authorizationCalls).toBe(0);
  });

  test("keeps a legacy-mapped team off hosted accounts until migration finishes", async () => {
    cutoverReady = false;
    const { body } = await get();
    expect(hostedExchangeCalls).toBe(0);
    expect(body.shared).toEqual({ kind: "migrationPending" });
    expect((body.claude as { kind: string }).kind).toBe("ok");
  });

  test("reports hosted tenant control that is not configured", async () => {
    hostedControlConfigured = false;
    const { body } = await get();
    expect(body.shared).toEqual({ kind: "notConfigured" });
    expect(hostedExchangeCalls).toBe(0);
  });

  test("offers the viewer's other account-managing teams as transfer destinations", async () => {
    authorizedTeams = [
      ...twoTeams(),
      { teamId: "team-3", teamName: "Team Three", use: true, manageAccounts: false },
    ];
    const { body } = await get("team-1");
    expect(body.transferTeams).toEqual([{ id: "team-2", name: "Team Two" }]);
  });

  test("lists only machines the team owns", async () => {
    const { body } = await get("team-1");
    expect(machineMetricsCalls).toEqual([["team-1", "dashboard"]]);
    const usage = body.machineUsage as { kind: string; machines: Array<{ vmId: string; displayName: string | null }> };
    expect(usage.kind).toBe("ready");
    expect(usage.machines.map((machine) => [machine.vmId, machine.displayName])).toEqual([
      ["0f4b1c2e-1111-4222-8333-444455556666", "builder-01"],
    ]);
  });

  test("reports machine usage as unavailable when per-machine metrics fail", async () => {
    machineMetricsKind = "unavailable";
    const { body } = await get("team-1");
    expect(body.machineUsage).toEqual({ kind: "unavailable", periodDays: 30 });
  });

  test("uses the Stack-selected team when the URL has no team scope", async () => {
    authorizedTeams = twoTeams();
    selectedTeamId = "team-2";
    await get();
    expect(metricsTeamIds).toEqual(["team-2"]);
  });

  test("ignores a requested team the viewer cannot open", async () => {
    authorizedTeams = twoTeams();
    selectedTeamId = "team-2";
    const { body } = await get("team-9");
    expect((body.selectedTeam as { id: string }).id).toBe("team-2");
  });

  test("normalizes a null or stale Stack selection to the personal team", async () => {
    authorizedTeams = [
      { teamId: "team-1", teamName: "Team One", use: true, manageAccounts: true },
      { teamId: "user-1", teamName: "Personal", use: true, manageAccounts: true, personal: true },
    ];
    selectedTeamId = null;
    await get();
    selectedTeamId = "stale-team";
    await get();
    expect(metricsTeamIds).toEqual(["user-1", "user-1"]);
  });

  test("rechecks live team grants on every request", async () => {
    await get("team-1");
    authorizedTeams = [];
    const { response } = await get("team-1");
    expect(authorizationCalls).toBe(2);
    expect(response.status).toBe(409);
    expect(metricsTeamIds).toEqual(["team-1"]);
  });
});
