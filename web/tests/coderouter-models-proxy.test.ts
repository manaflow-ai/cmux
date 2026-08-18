import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

let selectedAccounts = ["account-1"];
let unusableAccounts = new Set<string>();

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
  authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1" }),
  select: async () => {
    const id = selectedAccounts.shift();
    return id
      ? { id, vaultRevision: 1, credentialExpiresAt: new Date() }
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
});
