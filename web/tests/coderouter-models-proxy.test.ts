import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

let selectedAccounts = ["account-1"];
let unusableAccounts = new Set<string>();

const originalFetch = globalThis.fetch;
let upstreamUrl = "";
let upstreamHeaders = new Headers();
let upstreamStatuses: number[] = [];
let apiKeyAccounts = new Set<string>();
beforeAll(() => {
  globalThis.fetch = mock(async (...args: unknown[]) => {
    const [input, init] = args as [string | URL | Request, RequestInit | undefined];
    upstreamUrl = String(input);
    upstreamHeaders = new Headers(init?.headers);
    const status = upstreamStatuses.shift() ?? 200;
    return Response.json({ models: [{ slug: "gpt-test" }] }, { status });
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
    if (apiKeyAccounts.has(accountId)) {
      return { provider: "openai-apikey", apiKey: "sk-openai-key", accountId: "key:1", email: "work key" };
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
    apiKeyAccounts = new Set();
    upstreamHeaders = new Headers();
    upstreamStatuses = [];
  });

  test("a rate-limited last account answers no_usable_account, not the sibling's 429", async () => {
    selectedAccounts = ["account-1"];
    upstreamStatuses = [429];
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models", { headers: { authorization: "Bearer crt_route" } }),
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: "no_usable_account" });
  });

  test("lists the public API's models for an OpenAI API-key account with only its bearer", async () => {
    selectedAccounts = ["key-1"];
    apiKeyAccounts = new Set(["key-1"]);
    const response = await proxyCodexModels(
      new Request("https://coderouter.dev/v1/models", {
        headers: { authorization: "Bearer crt_route" },
      }),
    );
    expect(response.status).toBe(200);
    expect(upstreamUrl).toBe("https://api.openai.com/v1/models");
    expect(upstreamHeaders.get("authorization")).toBe("Bearer sk-openai-key");
    expect(upstreamHeaders.get("chatgpt-account-id")).toBeNull();
    expect(upstreamHeaders.get("originator")).toBeNull();
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
