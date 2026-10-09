import { vmToken } from "./vm-authorization-fixture";
import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/routeTokenAuth";

let selectedAccounts = ["account-1"];
let unusableAccounts = new Set<string>();
let authenticatedTokens: string[] = [];
const BOUND_TOKEN = await vmToken("vm-1", "team-1", "stack-user-1");

const originalFetch = globalThis.fetch;
let upstreamUrl = "";
beforeAll(() => {
  globalThis.fetch = mock(async (...args: unknown[]) => {
    const input = args[0] as string | URL | Request;
    upstreamUrl = String(input);
    return Response.json({ models: [{ slug: "gpt-test" }] });
  }) as typeof fetch;
});
afterAll(() => {
  globalThis.fetch = originalFetch;
});

const { createCodexModelsProxy } = await import("../services/coderouter/codexProxy");
const proxyCodexModels = createCodexModelsProxy({
  authenticate: async (token) => {
    authenticatedTokens.push(token);
    return {
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId: token === BOUND_TOKEN ? "vm-1" : null,
    };
  },
  select: async () => {
    const id = selectedAccounts.shift();
    return id
      ? { id, provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: new Date() }
      : null;
  },
  credential: async ({ accountId }) => {
    if (unusableAccounts.has(accountId)) {
      throw Object.assign(new Error("busy"), { _tag: "CodeRouterRefreshBusy" });
    }
    return {
      provider: "codex",
      accessToken: "provider-access",
      refreshToken: "provider-refresh",
      idToken: "provider-id",
      accountId: "chatgpt-account",
      email: "person@example.com",
      expiresAt: Date.now() + 60_000,
    };
  },
  cooldown: async () => {},
  providerRead: async (request) => await request(),
});

describe("coderouter models proxy", () => {
  beforeEach(() => {
    selectedAccounts = ["account-1"];
    unusableAccounts = new Set();
    authenticatedTokens = [];
  });

  test("forwards Codex model discovery through the authenticated account", async () => {
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models?client_version=0.146.0", {
        headers: { authorization: "Bearer crt_route" },
      }),
    );

    expect(response.status).toBe(200);
    expect(upstreamUrl).toBe(
      "https://chatgpt.com/backend-api/codex/models?client_version=0.146.0",
    );
    expect(await response.json()).toEqual({
      models: [{ slug: "gpt-test" }],
    });
  });

  test("routes around a refreshing or broken account", async () => {
    selectedAccounts = ["refreshing-account", "healthy-account"];
    unusableAccounts.add("refreshing-account");
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models?client_version=0.146.0", {
        headers: { authorization: "Bearer crt_route" },
      }),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      models: [{ slug: "gpt-test" }],
    });
  });

  test("accepts the private Pi route-token header", async () => {
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models?client_version=0.146.0", {
        headers: { "x-coderouter-route-token": "crt_route" },
      }),
    );
    expect(response.status).toBe(200);
  });

  test("a signed VM token needs no separate VM header", async () => {
    const models = (headers: Record<string, string>) =>
      proxyCodexModels(
        new Request("https://coderouter.dev/v1/models", {
          headers: {
            authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
            "x-cmux-authorization": `Bearer ${BOUND_TOKEN}`,
            ...headers,
          },
        }),
      );
    const matched = await models({ "x-cmux-vm-id": "vm-1" });
    expect(matched.status).toBe(200);

    selectedAccounts = ["account-1"];
    expect((await models({})).status).toBe(200);
    selectedAccounts = ["account-1"];
    expect((await models({ "x-cmux-vm-id": "vm-2" })).status).toBe(200);
    selectedAccounts = ["account-1"];
    expect((await models({ "x-cmux-authorization": "Bearer invalid" })).status).toBe(401);
  });

  test("the placeholder API key alone is rejected without a lookup", async () => {
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models", {
        headers: {
          authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
          "x-cmux-vm-id": "vm-1",
        },
      }),
    );
    expect(response.status).toBe(401);
    expect(authenticatedTokens).toEqual([]);
  });
});

describe("coderouter models proxy with no account configured", () => {
  function noAccountModelsProxy(configured: boolean) {
    const checks: string[] = [];
    const proxy = createCodexModelsProxy({
      authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1", vmId: null }),
      select: async () => null,
      credential: async () => {
        throw new Error("no account should be read");
      },
      cooldown: async () => {},
      providerRead: async (request) => await request(),
      hasConfiguredAccount: async (input) => {
        checks.push(input.teamId);
        return configured;
      },
    });
    return { proxy, checks };
  }

  const request = () => new Request("https://coderouter.dev/v1/models?client_version=0.146.0", {
    headers: { authorization: "Bearer crt_route" },
  });

  test("answers a caller that can see no Codex account with the terminal 403", async () => {
    const run = noAccountModelsProxy(false);
    const response = await run.proxy(request());
    expect(response.status).toBe(403);
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toEqual({
      error: {
        message: "No Codex account is configured for this team or shared with this caller. Add one with `cr add codex` or at coderouter.dev.",
        type: "invalid_request_error",
        code: "no_account_configured",
      },
    });
    expect(run.checks).toEqual(["team-1"]);
  });

  test("a caller whose accounts are all unavailable still gets a retryable 503", async () => {
    const run = noAccountModelsProxy(true);
    const response = await run.proxy(request());
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("15");
  });
});
