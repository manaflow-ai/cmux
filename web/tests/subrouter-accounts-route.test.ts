import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;
const secret = Buffer.alloc(32, 11).toString("base64");

let currentUser: unknown;
let fakeDb: ReturnType<typeof createFakeRouteDb>;
let upstream: ReturnType<typeof createMockSubrouter>;

const getUser = mock(async () => currentUser);
const cloudDb = mock(() => fakeDb);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../db/client", () => ({
  cloudDb,
  closeCloudDbForTests: async () => {},
}));

const accountsRoute = await import("../app/api/subrouter/accounts/route");
const accountRoute = await import("../app/api/subrouter/accounts/[accountId]/route");

afterAll(() => {
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  process.env.SUBROUTER_BASE_URL = "https://subrouter.test";
  process.env.SUBROUTER_ADMIN_TOKEN = "admin-test-token";
  process.env.SUBROUTER_TENANT_KEY_SECRET = secret;
  currentUser = stackUser();
  fakeDb = createFakeRouteDb();
  upstream = createMockSubrouter();
  globalThis.fetch = upstream.fetch as unknown as typeof fetch;
  getUser.mockClear();
  cloudDb.mockClear();
});

describe("subrouter accounts route", () => {
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

  test("returns 503 when subrouter env is not configured", async () => {
    delete process.env.SUBROUTER_ADMIN_TOKEN;
    delete process.env.SUBROUTER_TENANT_KEY_SECRET;

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(503);
    expect(JSON.parse(body)).toEqual({ error: "subrouter not configured" });
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
  });

  test("lists sanitized accounts through a lazily provisioned tenant", async () => {
    upstream.accounts = [{
      id: "acct-1",
      kind: "claude",
      label: "Claude Team",
      createdAt: "2026-07-01T00:00:00.000Z",
    }];

    const response = await accountsRoute.GET(request("/api/subrouter/accounts"));
    const body = await textWithoutTenantKeys(response);
    const json = JSON.parse(body) as {
      teamId: string;
      accounts: Array<{ id: string; kind: string; label: string }>;
    };

    expect(response.status).toBe(200);
    expect(json.teamId).toBe("team-a");
    expect(json.accounts).toEqual(upstream.accounts);
    expect(upstream.adminCreates).toBe(1);
    expect(upstream.tenantListCalls).toBe(1);
  });

  test("posts validated provider credentials with validate=1", async () => {
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
    expect(upstream.lastCreateAccountBody).toEqual({
      provider: "openai-apikey",
      label: "OpenAI",
      apiKey: "sk-test-openai",
    });
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
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.deletedAccountIds).toEqual(["acct-1"]);
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
    const response = await accountRoute.DELETE(
      request("/api/subrouter/accounts/acct-1?teamId=team-a", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "acct-1" }) },
    );
    const body = await textWithoutTenantKeys(response);

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({ ok: true, teamId: "team-a" });
    expect(upstream.deletedAccountIds).toEqual(["acct-1"]);
  });

  test("concurrent first calls create only one tenant and never expose tenant keys", async () => {
    const responses = await Promise.all([
      accountsRoute.GET(request("/api/subrouter/accounts")),
      accountsRoute.GET(request("/api/subrouter/accounts")),
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
      return jsonResponse(state.accounts);
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

    if (url.pathname.startsWith("/tenant/accounts/") && method === "DELETE") {
      expect(authorization).toBe("Bearer srt_1234567890abcdef1234567890abcdef");
      state.deletedAccountIds.push(decodeURIComponent(url.pathname.slice("/tenant/accounts/".length)));
      return jsonResponse({ ok: true });
    }

    return jsonResponse({ error: "not found" }, 404);
  });

  return state;
}

function createFakeRouteDb() {
  const rows: Array<{
    teamId: string;
    tenantId: string;
    tenantName: string;
    encryptedTenantKey: string;
  }> = [];
  let tail = Promise.resolve();

  return {
    rows,
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
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
