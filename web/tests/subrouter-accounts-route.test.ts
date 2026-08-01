import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;
const secret = Buffer.alloc(32, 11).toString("base64");
// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let currentUser: unknown;
let fakeDb: ReturnType<typeof createFakeRouteDb>;
let upstream: ReturnType<typeof createMockSubrouter>;
let useStubDb = false;

const getUser = mock(async () => currentUser);
const nonRedirectingSignOut = mock(async () => {});
const cloudDb = mock(() => fakeDb);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  getNonRedirectingStackServerApp: () => ({
    getUser,
    signOut: nonRedirectingSignOut,
  }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: (() =>
    useStubDb
      ? (cloudDb() as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb()) as typeof realCloudDb,
}));

const { encryptTenantKey } = await import("../services/subrouter/crypto");
const accountsRoute = await import("../app/api/subrouter/accounts/route");
const accountRoute = await import("../app/api/subrouter/accounts/[accountId]/route");
const accountRepairRoute = await import("../app/api/subrouter/accounts/[accountId]/repair/route");
const leasesRoute = await import("../app/api/subrouter/leases/route");
const leaseEventsRoute = await import("../app/api/subrouter/leases/[leaseId]/events/route");
const logoutRoute = await import("../app/api/subrouter/logout/route");
const teamsRoute = await import("../app/api/subrouter/teams/route");
const {
  SubrouterAuthorizationTimeoutError,
  withSubrouterAuthorizationDeadline,
} = await import("../services/vms/auth");
const { readBoundedJsonRecord } = await import(
  "../services/subrouter/boundedJson"
);

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  process.env.SUBROUTER_BASE_URL = "https://subrouter.test";
  process.env.SUBROUTER_ADMIN_TOKEN = "admin-test-token";
  process.env.SUBROUTER_TENANT_KEY_SECRET = secret;
  process.env.SUBROUTER_ALLOWED_TEAM_IDS = "team-a,team-b,team-c,user-1";
  process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "0";
  process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "10000";
  currentUser = stackUser();
  fakeDb = createFakeRouteDb();
  upstream = createMockSubrouter();
  globalThis.fetch = upstream.fetch as unknown as typeof fetch;
  getUser.mockClear();
  nonRedirectingSignOut.mockClear();
  cloudDb.mockClear();
});

describe("subrouter accounts route", () => {
  test("authorization deadline rejects work that ignores abort signals", async () => {
    process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "20";
    const operation = withSubrouterAuthorizationDeadline(
      async () => await new Promise<never>(() => {}),
    );

    await expect(operation).rejects.toBeInstanceOf(
      SubrouterAuthorizationTimeoutError,
    );
  });

  test("bounded JSON releases a body reader after stream errors", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new Error("stream failed"));
      },
    });
    const result = await readBoundedJsonRecord({
      body,
      headers: new Headers(),
    } as Request, 1024);

    expect(result).toEqual({ ok: false, status: 400 });
    expect(body.locked).toBe(false);
  });

  test("revokes the exact native Stack session on logout", async () => {
    const redirectingUserSignOut = mock(async () => {
      throw new Error("NEXT_REDIRECT");
    });
    currentUser = { ...stackUser(), signOut: redirectingUserSignOut };

    const response = await logoutRoute.POST(
      new Request("https://cmux.test/api/subrouter/logout", {
        method: "POST",
        headers: {
          authorization: "Bearer stack-access",
          "x-stack-refresh-token": "stack-refresh",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(redirectingUserSignOut).not.toHaveBeenCalled();
    expect(nonRedirectingSignOut).toHaveBeenCalledWith({
      tokenStore: {
        accessToken: "stack-access",
        refreshToken: "stack-refresh",
      },
    });
    expect(getUser).toHaveBeenCalledWith({
      tokenStore: {
        accessToken: "stack-access",
        refreshToken: "stack-refresh",
      },
    });
  });

  test("logout never falls back to an ambient browser session", async () => {
    currentUser = stackUser();

    const response = await logoutRoute.POST(
      request("/api/subrouter/logout", { method: "POST", auth: "cookie" }),
    );

    expect(response.status).toBe(401);
    expect(nonRedirectingSignOut).not.toHaveBeenCalled();
    expect(getUser).not.toHaveBeenCalled();
  });

  test("returns 401 when unauthenticated", async () => {
    currentUser = null;

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(401);
    expect(JSON.parse(body)).toEqual({ error: "unauthorized" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("rejects a team the caller is not a member of", async () => {
    const response = await accountsRoute.GET(request("/api/subrouter/accounts?teamId=team-not-mine"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "team_not_found" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("requires an explicit team when Stack has no selected scope", async () => {
    currentUser = {
      ...stackUser(),
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-b", displayName: "Team B" },
      ],
    };

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "team_selection_required",
    });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("rejects teams outside the private beta allowlist", async () => {
    process.env.SUBROUTER_ALLOWED_TEAM_IDS = "team-b";

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "team_not_allowed" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("separates team credential use from account management permissions", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    currentUser = {
      ...stackUser(),
      listPermissions: async () => [{ id: "subrouter:use" }],
    };

    const listResponse = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );
    expect(listResponse.status).toBe(200);

    const uploadResponse = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    expect(uploadResponse.status).toBe(403);
    expect(await uploadResponse.json()).toEqual({ error: "forbidden" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("fails closed when Stack permission enforcement is not configured", async () => {
    delete process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS;

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("fails closed when the team rollout allowlist is not configured", async () => {
    delete process.env.SUBROUTER_ALLOWED_TEAM_IDS;

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("lets account managers enumerate metadata without leasing credentials", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    currentUser = {
      ...stackUser(),
      listPermissions: async () => [
        { id: "subrouter:manage_accounts" },
      ],
    };

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts"),
    );

    expect(response.status).toBe(200);
  });

  test("returns 503 when subrouter env is not configured", async () => {
    delete process.env.SUBROUTER_ADMIN_TOKEN;
    delete process.env.SUBROUTER_TENANT_KEY_SECRET;

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(503);
    expect(JSON.parse(body)).toEqual({ error: "service_unavailable" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("returns 503 when a stored tenant key cannot be decrypted", async () => {
    fakeDb.rows.push({
      teamId: "team-a",
      tenantId: "tenant-team-a",
      tenantName: "Team A",
      encryptedTenantKey: "not-a-valid-encrypted-key",
    });

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(503);
    expect(JSON.parse(body)).toEqual({ error: "service_unavailable" });
    expect(upstream.tenantListCalls).toBe(0);
  });

  test("rejects request bodies larger than the byte limit", async () => {
    const oversized = JSON.stringify({
      provider: "openai-apikey",
      apiKey: "sk-test-openai",
      padding: "x".repeat(70 * 1024),
    });

    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts", { method: "POST", body: oversized }),
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(413);
    expect(JSON.parse(body)).toEqual({ error: "invalid_request" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("validates account upload shapes before proxying secrets", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        method: "POST",
        body: JSON.stringify({
          provider: "anthropic-apikey",
          apiKey: "definitely-not-an-anthropic-key",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(400);
    expect(JSON.parse(body)).toEqual({ error: "invalid_request" });
    expect(body).not.toContain("definitely-not-an-anthropic-key");
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("strips provider endpoint overrides before central credential storage", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          label: "Canary",
          tokens: {
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            idToken: "id-secret",
            accountID: "provider-account",
            tokenEndpoint: "https://attacker.example/collect",
            usageUrl: "https://attacker.example/usage",
            clientId: "attacker-client",
          },
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(upstream.lastCreateAccountBody).toEqual({
      provider: "codex",
      label: "Canary",
      tokens: {
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        idToken: "id-secret",
        accountID: "provider-account",
      },
    });
  });

  test("blocks cross-site cookie-authenticated account uploads before proxying", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        auth: "cookie",
        method: "POST",
        headers: {
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
          "content-type": "text/plain",
        },
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "forbidden" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("blocks cookie-authenticated account uploads without an Origin", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        auth: "cookie",
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "forbidden" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("allows same-origin cookie-authenticated account uploads", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        auth: "cookie",
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as { account: { kind: string } };

    expect(response.status).toBe(200);
    expect(json.account.kind).toBe("openai-apikey");
    expect(upstream.lastCreateAccountUrl?.searchParams.get("validate")).toBe("1");
    expect(upstream.lastCreateAccountUrl?.searchParams.get("adopt")).toBe("1");
  });

  test("returns an empty account list without provisioning when no tenant mapping exists", async () => {
    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ teamId: "team-a", accounts: [] });
    expect(upstream.fetch).not.toHaveBeenCalled();
    expect(upstream.adminCreates).toBe(0);
    expect(upstream.tenantListCalls).toBe(0);
    expect(fakeDb.insertCalls).toBe(0);
    expect(fakeDb.rows).toHaveLength(0);
  });

  test("lists sanitized accounts through an existing tenant", async () => {
    seedTenantMapping(fakeDb);
    upstream.accounts = [{
      id: "acct-1",
      provider: "claude",
      auth_mode: "oauth",
      label: "Claude Team",
      created_at: "2026-07-01T00:00:00.000Z",
      health: {
        ok: false,
        message: "Credential requires repair before it can be leased.",
        rawFailure: "refresh-secret",
      },
    }];

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as {
      teamId: string;
      accounts: Array<{ id: string; kind: string; label: string }>;
    };

    expect(response.status).toBe(200);
    expect(json.teamId).toBe("team-a");
    expect(json.accounts).toEqual([{
      id: "acct-1",
      kind: "claude",
      label: "Claude Team",
      createdAt: "2026-07-01T00:00:00.000Z",
      health: {
        ok: false,
        message: "Credential requires repair before it can be leased.",
      },
    }]);
    expect(body).not.toContain("refresh-secret");
    expect(upstream.adminCreates).toBe(0);
    expect(upstream.tenantListCalls).toBe(1);
  });

  test("treats explicit null account health as absent", async () => {
    seedTenantMapping(fakeDb);
    upstream.accounts = [{
      id: "acct-without-health",
      provider: "codex",
      auth_mode: "oauth",
      label: "Codex Team",
      health: null,
    }];

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      teamId: "team-a",
      accounts: [{
        id: "acct-without-health",
        kind: "codex",
        label: "Codex Team",
      }],
    });
  });

  test("strips unknown upstream account fields before returning to the browser", async () => {
    seedTenantMapping(fakeDb);
    upstream.accounts = [{
      id: "acct-leaky",
      kind: "claude",
      label: "Leaky",
      createdAt: "2026-07-01T00:00:00.000Z",
      apiKey: "sk-ant-should-never-leak",
      tokens: { refreshToken: "rt-should-never-leak" },
    }];

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as { accounts: Array<Record<string, unknown>> };

    expect(response.status).toBe(200);
    expect(json.accounts).toEqual([{
      id: "acct-leaky",
      kind: "claude",
      label: "Leaky",
      createdAt: "2026-07-01T00:00:00.000Z",
    }]);
    expect(body).not.toContain("should-never-leak");
  });

  test("adopts refresh custody and validates the provider credential", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          label: "OpenAI",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as { account: { kind: string; label: string } };

    expect(response.status).toBe(200);
    expect(json.account.kind).toBe("openai-apikey");
    expect(json.account.label).toBe("OpenAI");
    expect(upstream.lastCreateAccountUrl?.searchParams.get("validate")).toBe("1");
    expect(upstream.lastCreateAccountUrl?.searchParams.get("adopt")).toBe("1");
    expect(upstream.lastCreateAccountBody).toEqual({
      provider: "openai-apikey",
      label: "OpenAI",
      apiKey: "sk-test-openai",
    });
    expect(upstream.adminCreates).toBe(1);
    expect(fakeDb.rows).toHaveLength(1);
  });

  test("allows bearer-authenticated account uploads without an Origin", async () => {
    const response = await accountsRoute.POST(
      request("/api/subrouter/accounts?validate=1", {
        method: "POST",
        body: JSON.stringify({
          provider: "openai-apikey",
          apiKey: "sk-test-openai",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as { account: { kind: string } };

    expect(response.status).toBe(200);
    expect(json.account.kind).toBe("openai-apikey");
  });

  test("delete proxies to the tenant account endpoint", async () => {
    seedTenantMapping(fakeDb);
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.deletedAccountIds).toEqual(["acct-1"]);
  });

  test("repairs an account in place without returning credential fields", async () => {
    seedTenantMapping(fakeDb);
    const response = await accountRepairRoute.POST(
      request("/api/subrouter/accounts/acct-1/repair?validate=1", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          label: "Alice",
          tokens: {
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            idToken: "id-secret",
            accountID: "provider-account",
          },
        }),
      }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const text = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(upstream.lastRepairAccount?.accountId).toBe("acct-1");
    expect(upstream.lastRepairAccount?.validate).toBe("1");
    expect(upstream.lastRepairAccount?.adopt).toBe("1");
    expect(upstream.lastRepairAccount?.body).toEqual({
      provider: "codex",
      label: "Alice",
      tokens: {
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        idToken: "id-secret",
        accountID: "provider-account",
      },
    });
    expect(text).not.toContain("access-secret");
    expect(text).not.toContain("refresh-secret");
    expect(text).not.toContain("id-secret");
  });

  test("delete is a no-op when no tenant mapping exists", async () => {
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.fetch).not.toHaveBeenCalled();
    expect(fakeDb.insertCalls).toBe(0);
    expect(fakeDb.rows).toHaveLength(0);
  });

  test("blocks cross-site cookie-authenticated account deletes before proxying", async () => {
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", {
        auth: "cookie",
        method: "DELETE",
        headers: {
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
      }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "forbidden" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("blocks cookie-authenticated account deletes without an Origin", async () => {
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", {
        auth: "cookie",
        method: "DELETE",
      }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(403);
    expect(JSON.parse(body)).toEqual({ error: "forbidden" });
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  test("allows same-origin cookie-authenticated account deletes", async () => {
    seedTenantMapping(fakeDb);
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", {
        auth: "cookie",
        method: "DELETE",
        headers: { origin: "https://cmux.test" },
      }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.deletedAccountIds).toEqual(["acct-1"]);
  });

  test("allows bearer-authenticated account deletes without an Origin", async () => {
    seedTenantMapping(fakeDb);
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.deletedAccountIds).toEqual(["acct-1"]);
  });

  test("concurrent first account uploads create only one tenant and never expose tenant keys", async () => {
    const accountBody = JSON.stringify({
      provider: "openai-apikey",
      apiKey: "sk-test-openai",
    });
    const responses = await Promise.all([
      accountsRoute.POST(request("/api/subrouter/accounts", { method: "POST", body: accountBody })),
      accountsRoute.POST(request("/api/subrouter/accounts", { method: "POST", body: accountBody })),
    ]);
    const bodies = await Promise.all(responses.map(textWithoutTenantKeys));

    expect(responses.map((response) => response.status)).toEqual([200, 200]);
    expect(upstream.adminCreates).toBe(1);
    expect(fakeDb.rows).toHaveLength(1);
    expect(fakeDb.rows[0].encryptedTenantKey).not.toContain("srt_");
    for (const body of bodies) {
      expect(body).not.toContain("srt_");
    }
  });

  test("returns an access-only credential lease without exposing tenant or refresh keys", async () => {
    seedTenantMapping(fakeDb);
    const response = await leasesRoute.POST(
      request("/api/subrouter/leases", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          agentType: "codex",
          sessionId: "session-1",
          model: "gpt-5",
          requiredAuthMode: "oauth",
        }),
      }),
    );
    const body = await textWithoutTenantKeys(response);
    const parsed = JSON.parse(body) as {
      teamId: string;
      lease: { leaseId: string; token: string };
    };

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(parsed.teamId).toBe("team-a");
    expect(parsed.lease.leaseId).toBe("lease-1");
    expect(parsed.lease.token).toBe("leased-access-token");
    expect(body).not.toContain("refresh-token-that-must-not-leak");
    expect(upstream.lastLeaseBody).toEqual({
      provider: "codex",
      agentType: "codex",
      sessionId: "session-1",
      model: "gpt-5",
      requiredAuthMode: "oauth",
    });
  });

  test("rejects an invalid required credential auth mode", async () => {
    seedTenantMapping(fakeDb);
    const response = await leasesRoute.POST(
      request("/api/subrouter/leases", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          sessionId: "session-1",
          requiredAuthMode: "password",
        }),
      }),
    );

    expect(response.status).toBe(400);
    expect(upstream.lastLeaseBody).toBeNull();
  });

  test("does not provision a tenant when requesting a lease without shared accounts", async () => {
    const response = await leasesRoute.POST(
      request("/api/subrouter/leases", {
        method: "POST",
        body: JSON.stringify({
          provider: "claude",
          sessionId: "session-2",
        }),
      }),
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "no_shared_accounts" });
    expect(upstream.fetch).not.toHaveBeenCalled();
    expect(upstream.adminCreates).toBe(0);
  });

  test("bounds lease and outcome bodies before forwarding them", async () => {
    seedTenantMapping(fakeDb);
    const leaseResponse = await leasesRoute.POST(
      request("/api/subrouter/leases", {
        method: "POST",
        body: JSON.stringify({
          provider: "codex",
          sessionId: "x".repeat(20 * 1024),
        }),
      }),
    );
    expect(leaseResponse.status).toBe(413);

    const eventResponse = await leaseEventsRoute.POST(
      request("/api/subrouter/leases/lease-1/events", {
        method: "POST",
        body: JSON.stringify({
          outcome: "success",
          padding: "x".repeat(8 * 1024),
        }),
      }),
      { params: Promise.resolve({ leaseId: "lease-1" }) },
    );
    expect(eventResponse.status).toBe(413);
    expect(upstream.lastLeaseBody).toBeNull();
    expect(upstream.lastLeaseEvent).toBeNull();
  });

  test("reports a lease outcome through the same team tenant", async () => {
    seedTenantMapping(fakeDb);
    const response = await leaseEventsRoute.POST(
      request("/api/subrouter/leases/lease-1/events", {
        method: "POST",
        body: JSON.stringify({ outcome: "rate_limited", statusCode: 429 }),
      }),
      { params: Promise.resolve({ leaseId: "lease-1" }) },
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(upstream.lastLeaseEvent).toEqual({
      leaseId: "lease-1",
      body: { outcome: "rate_limited", statusCode: 429 },
    });
  });

  test("lists every Stack team plus the personal scope for CLI selection", async () => {
    const response = await teamsRoute.GET(request("/api/subrouter/teams"));
    const body = await response.json() as {
      selectedTeamId: string;
      teams: Array<{ id: string; personal: boolean }>;
    };

    expect(response.status).toBe(200);
    expect(body.selectedTeamId).toBe("team-a");
    expect(body.teams.map((team) => team.id)).toEqual([
      "team-a",
      "team-b",
      "user-1",
    ]);
    expect(body.teams.find((team) => team.id === "user-1")?.personal).toBe(true);
  });

  test("does not substitute the billing team for an absent Stack selection", async () => {
    currentUser = {
      ...stackUser(),
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-b", displayName: "Team B" },
      ],
    };

    const response = await teamsRoute.GET(request("/api/subrouter/teams"));
    const body = await response.json() as {
      selectedTeamId: string | null;
    };

    expect(response.status).toBe(200);
    expect(body.selectedTeamId).toBeNull();
  });

  test("looks up a requested team directly instead of paginating every team", async () => {
    const listTeams = mock(async (...args: unknown[]) => {
      const options = args[0] as {
        readonly cursor?: string;
        readonly query?: string;
      } | undefined;
      if (options?.query === "team-c") {
        return Object.assign(
          [{ id: "team-c", displayName: "Team C" }],
          { nextCursor: "unused-page" },
        );
      }
      return Object.assign(
        [{ id: "team-b", displayName: "Team B" }],
        { nextCursor: "page-2" },
      );
    });
    currentUser = { ...stackUser(), listTeams };

    const response = await accountsRoute.GET(
      request("/api/subrouter/accounts?teamId=team-c"),
    );

    expect(response.status).toBe(200);
    expect(listTeams).toHaveBeenCalledTimes(1);
    expect(listTeams).toHaveBeenCalledWith({
      query: "team-c",
      limit: 100,
    });
  });

  test("follows Stack team pagination before resolving CLI permissions", async () => {
    const firstPage = Object.assign(
      [{ id: "team-a", displayName: "Team A" }],
      { nextCursor: "page-2" },
    );
    const secondPage = Object.assign(
      [{ id: "team-c", displayName: "Team C" }],
      { nextCursor: null },
    );
    const listTeams = mock(async (...args: unknown[]) => {
      const options = args[0] as { readonly cursor?: string } | undefined;
      return options?.cursor === "page-2" ? secondPage : firstPage;
    });
    currentUser = { ...stackUser(), listTeams };

    const response = await teamsRoute.GET(request("/api/subrouter/teams"));
    const body = await response.json() as {
      teams: Array<{ id: string }>;
    };

    expect(response.status).toBe(200);
    expect(body.teams.map((team) => team.id)).toEqual([
      "team-a",
      "team-c",
      "user-1",
    ]);
    expect(listTeams).toHaveBeenCalledTimes(2);
    const listTeamCalls = (
      listTeams as unknown as { mock: { calls: unknown[][] } }
    ).mock.calls;
    expect(listTeamCalls[1]?.[0]).toMatchObject({
      cursor: "page-2",
      limit: 100,
    });
  });

  test("times out Stack team pagination as one authorization operation", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "20";
    let releaseFirstPage!: () => void;
    const firstPageReady = new Promise<void>((resolve) => {
      releaseFirstPage = resolve;
    });
    const listTeams = mock(async (...args: unknown[]) => {
      const options = args[0] as { readonly cursor?: string } | undefined;
      if (!options?.cursor) {
        await firstPageReady;
        return Object.assign(
          [{ id: "team-a", displayName: "Team A" }],
          { nextCursor: "page-2" },
        );
      }
      return Object.assign([], { nextCursor: null });
    });
    currentUser = { ...stackUser(), listTeams };

    const routePromise = teamsRoute.GET(request("/api/subrouter/teams"));
    const result = await Promise.race([
      routePromise,
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 100)),
    ]);
    releaseFirstPage();
    await routePromise;

    expect(result?.status).toBe(503);
    expect(listTeams).toHaveBeenCalledTimes(1);
  });

  test("bounds timed-out Stack permission work across concurrent requests", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "20";
    let releasePermissions!: () => void;
    const permissionsReady = new Promise<void>((resolve) => {
      releasePermissions = resolve;
    });
    let active = 0;
    let maxActive = 0;
    let reportPermissionsDrained!: () => void;
    const permissionsDrained = new Promise<void>((resolve) => {
      reportPermissionsDrained = resolve;
    });
    const listPermissions = mock(async () => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await permissionsReady;
      active -= 1;
      if (active === 0) reportPermissionsDrained();
      return [{ id: "subrouter:use" }];
    });
    currentUser = {
      ...stackUser(),
      listPermissions,
    };

    const routes = Array.from(
      { length: 12 },
      () => teamsRoute.GET(request("/api/subrouter/teams")),
    );
    const responses = await Promise.all(routes);
    releasePermissions();
    await permissionsDrained;

    expect(responses.every((response) => response.status === 503)).toBe(true);
    expect(maxActive).toBeLessThanOrEqual(8);
  });

  test("opens a bounded circuit after every Stack authorization slot hangs", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "20";
    let releasePermissions!: () => void;
    const permissionsReady = new Promise<void>((resolve) => {
      releasePermissions = resolve;
    });
    const listPermissions = mock(async () => {
      await permissionsReady;
      return [{ id: "subrouter:use" }];
    });
    currentUser = {
      ...stackUser(),
      listPermissions,
    };

    const saturated = Array.from(
      { length: 8 },
      () => teamsRoute.GET(request("/api/subrouter/teams")),
    );
    await Promise.all(saturated);
    expect(listPermissions).toHaveBeenCalledTimes(8);

    process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS = "1000";
    const probe = teamsRoute.GET(request("/api/subrouter/teams"));
    const result = await Promise.race([
      probe,
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 100)),
    ]);

    releasePermissions();
    await probe;
    expect(result?.status).toBe(503);
    expect(listPermissions).toHaveBeenCalledTimes(8);
  });

  test("resolves one permission snapshot per scope with bounded concurrency", async () => {
    process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";
    process.env.SUBROUTER_ALLOWED_TEAM_IDS = "*";
    const teams = Array.from({ length: 12 }, (_, index) => ({
      id: `team-${index}`,
      displayName: `Team ${index}`,
    }));
    let active = 0;
    let maxActive = 0;
    let releasePermissions!: () => void;
    const permissionsReleased = new Promise<void>((resolve) => {
      releasePermissions = resolve;
    });
    let reportOverlap!: () => void;
    const overlapObserved = new Promise<void>((resolve) => {
      reportOverlap = resolve;
    });
    const listPermissions = mock(async () => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      if (active >= 2) reportOverlap();
      await permissionsReleased;
      active -= 1;
      return [
        { id: "subrouter:use" },
        { id: "subrouter:manage_accounts" },
      ];
    });
    const hasPermission = mock(async () => {
      throw new Error("hasPermission performs a duplicate permission request");
    });
    currentUser = {
      ...stackUser(),
      selectedTeam: teams[0],
      listTeams: async () => teams,
      listPermissions,
      hasPermission,
    };

    const responsePromise = teamsRoute.GET(request("/api/subrouter/teams"));
    await overlapObserved;
    releasePermissions();
    const response = await responsePromise;
    const body = await response.json() as {
      teams: Array<{ id: string }>;
    };

    expect(response.status).toBe(200);
    expect(body.teams).toHaveLength(teams.length + 1);
    expect(listPermissions).toHaveBeenCalledTimes(teams.length + 1);
    expect(hasPermission).not.toHaveBeenCalled();
    expect(maxActive).toBeGreaterThan(1);
    expect(maxActive).toBeLessThanOrEqual(8);
  });
});

type TestRequestInit = RequestInit & {
  readonly auth?: "bearer" | "cookie";
};

function request(path: string, init: TestRequestInit = {}): Request {
  const headers = new Headers(init.headers);
  if (!headers.has("content-type")) headers.set("content-type", "application/json");
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

async function textWithoutTenantKeys(response: Response): Promise<string> {
  const text = await response.text();
  expect(text).not.toContain("srt_");
  return text;
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

function createMockSubrouter() {
  const state = {
    adminCreates: 0,
    tenantListCalls: 0,
    accounts: [] as Array<Record<string, unknown>>,
    deletedAccountIds: [] as string[],
    lastCreateAccountUrl: null as URL | null,
    lastCreateAccountBody: null as unknown,
    lastLeaseBody: null as unknown,
    lastLeaseEvent: null as {
      leaseId: string;
      body: unknown;
    } | null,
    lastRepairAccount: null as {
      accountId: string;
      validate: string | null;
      adopt: string | null;
      body: unknown;
    } | null,
    fetch: undefined as unknown as ReturnType<typeof mock>,
  };

  state.fetch = mock(async (...args: unknown[]): Promise<Response> => {
    const input = args[0] as RequestInfo | URL;
    const init = args[1] as RequestInit | undefined;
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const authorization = new Headers(init?.headers).get("authorization") ?? "";

    if (url.pathname === "/admin/tenants" && method === "POST") {
      expect(authorization).toBe("Bearer admin-test-token");
      state.adminCreates += 1;
      const body = JSON.parse(String(init?.body ?? "{}")) as { name?: string };
      return jsonResponse({
        id: "tenant-team-a",
        name: body.name ?? "Team A",
        key: "srt_1234567890abcdef1234567890abcdef",
      });
    }

    if (url.pathname === "/tenant/accounts" && method === "GET") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.tenantListCalls += 1;
      return jsonResponse({ accounts: state.accounts });
    }

    if (url.pathname === "/tenant/accounts" && method === "POST") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.lastCreateAccountUrl = url;
      state.lastCreateAccountBody = JSON.parse(String(init?.body ?? "{}"));
      const body = state.lastCreateAccountBody as { provider: string; label?: string };
      const account = {
        id: "acct-created",
        kind: body.provider,
        label: body.label ?? null,
        createdAt: "2026-07-02T00:00:00.000Z",
      };
      state.accounts.push(account);
      return jsonResponse(account);
    }

    const repairMatch = url.pathname.match(
      /^\/tenant\/accounts\/([^/]+)\/repair$/,
    );
    if (repairMatch && method === "POST") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.lastRepairAccount = {
        accountId: decodeURIComponent(repairMatch[1]),
        validate: url.searchParams.get("validate"),
        adopt: url.searchParams.get("adopt"),
        body: JSON.parse(String(init?.body ?? "{}")),
      };
      return jsonResponse({
        id: state.lastRepairAccount.accountId,
        provider: "codex",
        auth_mode: "oauth",
        label: "Alice",
        accessToken: "must-not-leak",
        refreshToken: "must-not-leak",
      });
    }

    if (url.pathname.startsWith("/tenant/accounts/") && method === "DELETE") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.deletedAccountIds.push(decodeURIComponent(url.pathname.slice("/tenant/accounts/".length)));
      return jsonResponse({ ok: true });
    }

    if (url.pathname === "/tenant/leases" && method === "POST") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.lastLeaseBody = JSON.parse(String(init?.body ?? "{}"));
      return jsonResponse({
        leaseId: "lease-1",
        accountId: "account-1",
        provider: "codex",
        authMode: "oauth",
        token: "leased-access-token",
        providerAccountId: "provider-account-1",
        label: "Shared Codex",
        credentialGeneration: 4,
        issuedAt: "2026-07-28T00:00:00.000Z",
        expiresAt: "2026-07-28T00:05:00.000Z",
        credentialExpiresAt: "2026-07-28T01:00:00.000Z",
        refreshToken: "refresh-token-that-must-not-leak",
      });
    }

    const leaseEventMatch = url.pathname.match(/^\/tenant\/leases\/([^/]+)\/events$/);
    if (leaseEventMatch && method === "POST") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.lastLeaseEvent = {
        leaseId: decodeURIComponent(leaseEventMatch[1]),
        body: JSON.parse(String(init?.body ?? "{}")),
      };
      return jsonResponse({ ok: true });
    }

    return jsonResponse({ error: "not found" }, 404);
  });

  return state;
}

function seedTenantMapping(db: ReturnType<typeof createFakeRouteDb>) {
  db.rows.push({
    teamId: "team-a",
    tenantId: "tenant-team-a",
    tenantName: "Team A",
    encryptedTenantKey: encryptTenantKey("srt_1234567890abcdef1234567890abcdef", secret),
  });
}

function createFakeRouteDb() {
  const rows: Array<{
    teamId: string;
    tenantId: string;
    tenantName: string;
    encryptedTenantKey: string;
  }> = [];
  let tail = Promise.resolve();

  const db = {
    rows,
    insertCalls: 0,
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => rows.slice(0, 1),
        }),
      }),
    }),
    transaction: async <T>(callback: (tx: unknown) => Promise<T>): Promise<T> => {
      const run = tail.then(async () => {
        const tx = {
          execute: async () => [],
          select: () => ({
            from: () => ({
              where: () => ({
                limit: async () => rows.slice(0, 1),
              }),
            }),
          }),
          insert: () => ({
            values: async (row: (typeof rows)[number]) => {
              db.insertCalls += 1;
              rows.push(row);
            },
          }),
        };
        return await callback(tx);
      });
      tail = run.then(() => undefined, () => undefined);
      return await run;
    },
  };
  return db;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
