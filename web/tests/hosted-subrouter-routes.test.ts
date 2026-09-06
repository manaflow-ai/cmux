import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const modifiedEnvironment = [
  "SUBROUTER_STACK_AUTH_TIMEOUT_MS",
  "SUBROUTER_HOSTED_URL",
  "SUBROUTER_STACK_TENANT_DELETE_TOKEN",
] as const;
const originalEnvironment = Object.fromEntries(
  modifiedEnvironment.map((name) => [name, process.env[name]]),
) as Record<(typeof modifiedEnvironment)[number], string | undefined>;

process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "10000";
process.env.SUBROUTER_HOSTED_URL = "https://sr.test";
process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN =
  "0123456789abcdef0123456789abcdef-test";

let currentUser: ReturnType<typeof stackUser> | null = null;
let authJson = {
  accessToken: "cookie-access",
  refreshToken: "cookie-refresh",
};
let authJsonError: Error | null = null;
const getUser = mock(async () => currentUser);
const getAuthJson = mock(async () => {
  if (authJsonError) throw authJsonError;
  return authJson;
});
const signOut = mock(async () => {});
let hostedCutoverReady = true;
const hostedSubrouterCutoverReadyForTeam = mock(async () => hostedCutoverReady);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser, getAuthJson }),
  getNonRedirectingStackServerApp: () => ({ getUser, signOut }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));
mock.module("../services/subrouter/cutover", () => ({
  hostedSubrouterCutoverReadyForTeam,
}));
const captureCoderouterEvent = mock(() => {});
mock.module("../services/coderouter/analytics", () => ({
  captureCoderouterEvent,
}));

const accountsRoute = await import("../app/api/subrouter/accounts/route");
const accountRoute = await import(
  "../app/api/subrouter/accounts/[accountId]/route"
);
const repairRoute = await import(
  "../app/api/subrouter/accounts/[accountId]/repair/route"
);
const leasesRoute = await import("../app/api/subrouter/leases/route");
const leaseEventsRoute = await import(
  "../app/api/subrouter/leases/[leaseId]/events/route"
);
const logoutRoute = await import("../app/api/subrouter/logout/route");
const teamsRoute = await import("../app/api/subrouter/teams/route");
const organizationsRoute = await import(
  "../app/api/coderouter/organizations/route"
);
const exchangeRoute = await import("../app/api/subrouter/exchange/route");

const originalFetch = globalThis.fetch;
const tenantKey = "srt_0123456789abcdef0123456789abcdef";
let calls: Array<{
  readonly url: URL;
  readonly method: string;
  readonly headers: Headers;
  readonly body: unknown;
}> = [];
let listedAccounts: unknown[] = [];
let exchangeStatus = 200;
let accountListStatus = 200;

afterAll(() => {
  globalThis.fetch = originalFetch;
  for (const name of modifiedEnvironment) {
    const value = originalEnvironment[name];
    if (value === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = value;
    }
  }
});

beforeEach(() => {
  currentUser = stackUser();
  authJson = {
    accessToken: "cookie-access",
    refreshToken: "cookie-refresh",
  };
  authJsonError = null;
  calls = [];
  listedAccounts = [];
  hostedCutoverReady = true;
  exchangeStatus = 200;
  accountListStatus = 200;
  getUser.mockClear();
  getAuthJson.mockClear();
  signOut.mockClear();
  hostedSubrouterCutoverReadyForTeam.mockClear();
  captureCoderouterEvent.mockClear();
  globalThis.fetch = hostedFetch as typeof fetch;
});

describe("hosted Subrouter account routes", () => {
  test("brokers native tenant exchange only after the shared cutover gate", async () => {
    hostedCutoverReady = false;
    const pending = await exchangeRoute.POST(
      request("/api/subrouter/exchange", { method: "POST", body: "{}" }),
    );
    expect(pending.status).toBe(503);
    expect(await pending.json()).toEqual({
      error: "subrouter_migration_pending",
    });
    expect(calls).toHaveLength(0);

    hostedCutoverReady = true;
    const response = await exchangeRoute.POST(
      request("/api/subrouter/exchange", { method: "POST", body: "{}" }),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(calls[0]?.headers.get("x-subrouter-stack-control-token")).toBe(
      "0123456789abcdef0123456789abcdef-test",
    );
    expect(calls[0]?.body).toEqual({
      teamId: "team-a",
      teamName: "Team A",
      capabilities: ["use", "manage_accounts"],
    });
    expect(await response.json()).toEqual({
      tenantId: "team-a",
      tenantName: "Team A",
      tenantKey,
      proxyUrl: `https://sr.test/t/${tenantKey}`,
      capabilities: ["use", "manage_accounts"],
    });
  });

  test("never returns a tenant key from ambient browser cookies", async () => {
    const response = await exchangeRoute.POST(
      request("/api/subrouter/exchange", {
        auth: "cookie",
        method: "POST",
        body: "{}",
      }),
    );
    expect(response.status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  test("returns service unavailable when hosted tenant control is not configured", async () => {
    const configuredToken = process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN;
    delete process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN;
    try {
      const response = await exchangeRoute.POST(
        request("/api/subrouter/exchange", { method: "POST", body: "{}" }),
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "service_unavailable" });
      expect(calls).toHaveLength(0);
    } finally {
      if (configuredToken === undefined) {
        delete process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN;
      } else {
        process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN = configuredToken;
      }
    }
  });

  test("returns 401 without a Stack user and never contacts hosted Subrouter", async () => {
    currentUser = null;

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(calls).toHaveLength(0);
  });

  test("returns 401 when cookie auth has no Stack access token", async () => {
    authJson = {
      accessToken: "",
      refreshToken: "",
    };

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts", { auth: "cookie" }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(calls).toHaveLength(0);
  });

  test("fails closed before hosted cutover for an unmigrated legacy team", async () => {
    hostedCutoverReady = false;

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "subrouter_migration_pending",
    });
    expect(calls).toHaveLength(0);
    expect(getAuthJson).not.toHaveBeenCalled();
  });

  test("rejects a team outside the caller's Stack memberships", async () => {
    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts?teamId=other-team"),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "team_not_found" });
    expect(calls).toHaveLength(0);
  });

  test("rejects a team the caller is not a member of even when it exists elsewhere", async () => {
    // Membership is the only requirement, and it is checked against the
    // caller's own team list; a team missing from that list is 403 for every
    // verb, including mutations.
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?teamId=team-c", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "work",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "team_not_found" });
    expect(calls).toHaveLength(0);
  });

  test("any member can use and manage accounts without a Stack permission", async () => {
    // The user holds no Stack team permissions at all (listPermissions is
    // empty) and team-b is not the selected team. Membership alone grants
    // both capabilities, so the hosted tenant exchange asks for both and the
    // upload succeeds.
    currentUser = Object.assign(stackUser(), {
      listPermissions: async () => [],
    });

    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?teamId=team-b", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "work",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(calls[0]?.url.pathname).toBe("/_subrouter/auth/stack");
    expect(calls[0]?.body).toEqual({
      teamId: "team-b",
      teamName: "Team B",
      capabilities: ["use", "manage_accounts"],
    });
    expect(calls[1]?.url.pathname).toBe("/_subrouter/accounts");
  });

  test("blocks cross-site cookie mutations before exchanging a tenant", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        auth: "cookie",
        method: "POST",
        headers: {
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "work",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(calls).toHaveLength(0);
  });

  test("uses a cookie Stack token for same-origin account uploads", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        auth: "cookie",
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "work",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      teamId: "team-a",
      account: {
        id: "apikey:openai-apikey:work",
        kind: "openai-apikey",
        label: "work",
      },
    });
    expect(calls[0]?.headers.get("authorization")).toBe("Bearer cookie-access");
    expect(calls[1]?.body).toEqual({
      provider: "openai-apikey",
      label: "work",
      apiKey: "sk-test",
    });
  });

  test("forwards the authoritative refreshed native Stack token", async () => {
    authJson = {
      accessToken: "refreshed-access",
      refreshToken: "refreshed-refresh",
    };

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(200);
    expect(calls[0]?.headers.get("authorization")).toBe(
      "Bearer refreshed-access",
    );
    expect(getAuthJson).toHaveBeenCalledWith({
      tokenStore: {
        accessToken: "access-token",
        refreshToken: "refresh-token",
      },
    });
  });

  test("maps a Stack token refresh outage to service unavailable", async () => {
    authJsonError = new Error("Stack refresh unavailable");

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
    expect(calls).toHaveLength(0);
  });

  test("strips unknown account fields returned by the Go service", async () => {
    listedAccounts = [{
      id: "alice@example.com",
      provider: "codex",
      auth_mode: "oauth",
      email: "alice@example.com",
      label: "Alice work",
      created_at: "2026-08-03T00:00:00Z",
      health: { ok: false, message: "upstream detail must not leak" },
      refreshToken: "must-not-leak",
      nested: { accessToken: "must-not-leak" },
    }];

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const text = await response.text();

    expect(response.status).toBe(200);
    expect(JSON.parse(text)).toEqual({
      teamId: "team-a",
      accounts: [{
        id: "alice@example.com",
        kind: "codex",
        label: "Alice work",
        createdAt: "2026-08-03T00:00:00Z",
        health: { ok: false },
      }],
    });
    expect(text).not.toContain("must-not-leak");
    expect(text).not.toContain("upstream detail must not leak");
    expect(text).not.toContain(tenantKey);
    expect(captureCoderouterEvent).toHaveBeenCalledWith({
      event: "coderouter_account_status_viewed",
      teamId: "team-a",
      properties: {
        source: "legacy_dashboard",
        account_count: 1,
        account_error_count: 0,
      },
    });
  });

  test("maps internal tenant-key authentication failures to an upstream error", async () => {
    accountListStatus = 401;

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({
      error: "upstream_request_failed",
    });
  });

  test("preserves caller authentication failures from the Stack exchange", async () => {
    exchangeStatus = 401;

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: "upstream_request_failed",
    });
  });

  test("validates and bounds uploads before forwarding provider secrets", async () => {
    const invalid = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        method: "POST",
        body: JSON.stringify({
          provider: "anthropic-apikey",
          apiKey: "wrong-prefix",
        }),
      }),
    );
    expect(invalid.status).toBe(400);
    expect(calls).toHaveLength(0);

    const oversized = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test",
          padding: "x".repeat(70 * 1024),
        }),
      }),
    );
    expect(oversized.status).toBe(413);
    expect(calls).toHaveLength(0);
  });

  test("keeps only supported Codex token fields before upload", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          label: "Alice",
          tokens: {
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountID: "account",
            tokenEndpoint: "https://attacker.example/collect",
          },
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(calls[1]?.body).toEqual({
      provider: "codex",
      label: "Alice",
      tokens: {
        accessToken: "access",
        refreshToken: "refresh",
        idToken: "id",
        accountID: "account",
      },
    });
    expect(captureCoderouterEvent).toHaveBeenCalledWith({
      event: "coderouter_account_added",
      userId: "user-1",
      teamId: "team-a",
      properties: {
        provider: "codex",
        source: "legacy_dashboard",
        already_exists: false,
      },
    });
  });

  test("deletes and repairs only the requested tenant account", async () => {
    const deleted = await accountRoute.DELETE(
      request("/api/subrouter/accounts/old%40example.com", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "old@example.com" }) },
    );
    expect(deleted.status).toBe(200);
    expect(calls[1]?.url.pathname).toBe(
      "/_subrouter/accounts/old%40example.com",
    );
    expect(calls[1]?.headers.get("authorization")).toBe(`Bearer ${tenantKey}`);
    expect(calls[1]?.url.href).not.toContain(tenantKey);
    expect(captureCoderouterEvent).toHaveBeenCalledWith({
      event: "coderouter_account_removed",
      userId: "user-1",
      teamId: "team-a",
      properties: { source: "legacy_dashboard" },
    });

    calls = [];
    const repaired = await repairRoute.POST(
      request("/api/subrouter/accounts/apikey%3Aopenai-apikey%3Awork/repair", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "work",
          apiKey: "sk-new",
        }),
      }),
      { params: Promise.resolve({ accountId: "apikey:openai-apikey:work" }) },
    );
    expect(repaired.status).toBe(200);
    expect(calls.map((call) => call.method)).toEqual(["POST", "POST"]);
    expect(calls[1]?.url.pathname).toBe("/_subrouter/accounts");
    expect(calls[1]?.headers.get("authorization")).toBe(`Bearer ${tenantKey}`);
    expect(calls[1]?.url.href).not.toContain(tenantKey);
    expect(calls[1]?.body).toEqual({
      provider: "openai-apikey",
      label: "work",
      apiKey: "sk-new",
      targetAccountID: "apikey:openai-apikey:work",
    });
    expect(captureCoderouterEvent).toHaveBeenCalledWith({
      event: "coderouter_account_added",
      userId: "user-1",
      teamId: "team-a",
      properties: {
        provider: "openai-apikey",
        source: "legacy_dashboard",
        already_exists: true,
      },
    });
  });

  test("keeps shipped lease, team, and logout routes working", async () => {
    const leaseResponse = await leasesRoute.POST(
      request("/api/subrouter/leases", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          sessionId: "session-1",
          agentType: "codex",
        }),
      }),
    );
    expect(leaseResponse.status).toBe(200);
    expect(leaseResponse.headers.get("cache-control")).toBe("no-store");
    expect(await leaseResponse.json()).toEqual({
      teamId: "team-a",
      lease: {
        leaseId: "lease-1",
        accountId: "alice@example.com",
        provider: "codex",
        authMode: "oauth",
        token: "leased-token",
        label: "Alice",
        credentialGeneration: 1,
        issuedAt: "2026-08-03T00:00:00Z",
        expiresAt: "2026-08-03T00:05:00Z",
      },
    });
    expect(calls.map((call) => call.url.pathname)).toEqual([
      "/_subrouter/auth/stack",
      "/_subrouter/leases",
    ]);

    calls = [];
    const eventResponse = await leaseEventsRoute.POST(
      request("/api/subrouter/leases/lease-1/events", {
        method: "POST",
        body: JSON.stringify({ outcome: "success", statusCode: 200 }),
      }),
      { params: Promise.resolve({ leaseId: "lease-1" }) },
    );
    expect(eventResponse.status).toBe(200);
    expect(await eventResponse.json()).toEqual({ ok: true });
    expect(calls.map((call) => call.url.pathname)).toEqual([
      "/_subrouter/auth/stack",
      "/_subrouter/leases/lease-1/events",
    ]);

    const teamsResponse = await teamsRoute.GET(
      request("/api/subrouter/teams"),
    );
    expect(teamsResponse.status).toBe(200);
    expect(await teamsResponse.json()).toEqual({
      selectedTeamId: "team-a",
      teams: [
        {
          id: "team-a",
          name: "Team A",
          personal: false,
          permissions: { use: true, manageAccounts: true },
        },
        {
          id: "team-b",
          name: "Team B",
          personal: false,
          permissions: { use: true, manageAccounts: true },
        },
        {
          id: "user-1",
          name: "User One",
          personal: true,
          permissions: { use: true, manageAccounts: true },
        },
      ],
    });

    const organizationsResponse = await organizationsRoute.GET(
      request("/api/coderouter/organizations", {
        headers: {
          cookie:
            "cmux_coderouter_organization=%5B%22user-1%22%2C%22team-b%22%5D",
        },
      }),
    );
    expect(organizationsResponse.status).toBe(200);
    expect(await organizationsResponse.json()).toEqual({
      selectedTeamId: "team-b",
      teams: [
        {
          id: "team-a",
          name: "Team A",
          personal: false,
          permissions: { use: true, manageAccounts: true },
        },
        {
          id: "team-b",
          name: "Team B",
          personal: false,
          permissions: { use: true, manageAccounts: true },
        },
        {
          id: "user-1",
          name: "User One",
          personal: true,
          permissions: { use: true, manageAccounts: true },
        },
      ],
    });

    const unauthorizedScopeResponse = await organizationsRoute.GET(
      request("/api/coderouter/organizations", {
        headers: {
          cookie:
            "cmux_coderouter_organization=%5B%22user-1%22%2C%22team-not-authorized%22%5D",
        },
      }),
    );
    expect(unauthorizedScopeResponse.status).toBe(200);
    expect((await unauthorizedScopeResponse.json()).selectedTeamId).toBe(
      "team-a",
    );

    const logoutResponse = await logoutRoute.POST(
      request("/api/subrouter/logout", { method: "POST" }),
    );
    expect(logoutResponse.status).toBe(200);
    expect(await logoutResponse.json()).toEqual({ ok: true });
    expect(signOut).toHaveBeenCalledWith({
      tokenStore: {
        accessToken: "access-token",
        refreshToken: "refresh-token",
      },
    });
  });
});

type TestRequestInit = RequestInit & {
  readonly auth?: "bearer" | "cookie";
};

function request(path: string, init: TestRequestInit = {}): Request {
  const headers = new Headers(init.headers);
  if (!headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  if (init.auth !== "cookie") {
    headers.set("authorization", "Bearer access-token");
    headers.set("x-stack-refresh-token", "refresh-token");
  }
  return new Request(`https://cmux.test${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body,
  });
}

function stackUser() {
  return {
    id: "user-1",
    displayName: "User One",
    primaryEmail: "user@example.com",
    selectedTeam: { id: "team-a", displayName: "Team A" },
    listTeams: async () => [
      { id: "team-a", displayName: "Team A" },
      { id: "team-b", displayName: "Team B" },
    ],
  };
}

async function hostedFetch(
  input: string | URL | Request,
  init?: RequestInit,
): Promise<Response> {
  const url = new URL(String(input));
  const method = init?.method ?? "GET";
  const headers = new Headers(init?.headers);
  const body = typeof init?.body === "string"
    ? JSON.parse(init.body)
    : undefined;
  calls.push({ url, method, headers, body });

  if (url.pathname === "/_subrouter/auth/stack" && method === "POST") {
    if (exchangeStatus !== 200) {
      return Response.json({ error: "unauthorized" }, { status: exchangeStatus });
    }
    return Response.json({
      tenantId: body.teamId,
      tenantName: body.teamName,
      tenantKey,
      proxyUrl: `https://sr.test/t/${tenantKey}`,
      capabilities: body.capabilities,
    });
  }
  if (
    url.pathname === "/_subrouter/accounts" &&
    headers.get("authorization") === `Bearer ${tenantKey}` &&
    method === "GET"
  ) {
    if (accountListStatus !== 200) {
      return Response.json(
        { error: "tenant credential rejected" },
        { status: accountListStatus },
      );
    }
    return Response.json(listedAccounts);
  }
  if (
    url.pathname === "/_subrouter/accounts" &&
    headers.get("authorization") === `Bearer ${tenantKey}` &&
    method === "POST"
  ) {
    const upload = body as { provider: string; label?: string };
    const id = upload.provider.endsWith("-apikey")
      ? `apikey:${upload.provider}:${upload.label ?? "unlabeled"}`
      : upload.label ?? "account";
    return Response.json({
      account: {
        id,
        kind: upload.provider,
        label: upload.label,
        refreshToken: "must-not-leak",
      },
    });
  }
  if (
    url.pathname === "/_subrouter/leases" &&
    headers.get("authorization") === `Bearer ${tenantKey}` &&
    method === "POST"
  ) {
    return Response.json({
      teamId: "team-a",
      lease: {
        leaseId: "lease-1",
        accountId: "alice@example.com",
        provider: "codex",
        authMode: "oauth",
        token: "leased-token",
        label: "Alice",
        credentialGeneration: 1,
        issuedAt: "2026-08-03T00:00:00Z",
        expiresAt: "2026-08-03T00:05:00Z",
      },
    });
  }
  if (
    url.pathname === "/_subrouter/leases/lease-1/events" &&
    headers.get("authorization") === `Bearer ${tenantKey}` &&
    method === "POST"
  ) {
    return new Response(null, { status: 204 });
  }
  if (
    url.pathname.startsWith("/_subrouter/accounts/") &&
    headers.get("authorization") === `Bearer ${tenantKey}` &&
    method === "DELETE"
  ) {
    return new Response(null, { status: 204 });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
