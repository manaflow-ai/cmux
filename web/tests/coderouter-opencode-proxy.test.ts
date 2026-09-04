import { describe, expect, test } from "bun:test";
import {
  __test,
  activeProviderKinds,
  createOpenCodeClientConfig,
  planeProviders,
} from "../services/coderouter/opencodeProxy";
import type { CodeRouterAccountSummary } from "../services/coderouter/types";

describe("coderouter OpenCode Go proxy", () => {
  test("rewrites provider traffic through the serving origin without upstream secrets", () => {
    const rewritten = __test.rewriteProviders({
      go: {
        name: "OpenCode Go",
        npm: "@ai-sdk/openai-compatible",
        api: { url: "https://models.example.test/v1", package: "@ai-sdk/openai-compatible" },
        options: { apiKey: "upstream-secret", headers: { secret: "value" }, mode: "go" },
        models: {
          "model-1": {
            name: "Model One",
            provider: {
              id: "go",
              name: "OpenCode Go",
              npm: "@ai-sdk/openai-compatible",
              apiKey: "nested-upstream-secret",
              headers: { authorization: "nested-secret" },
            },
          },
        },
      },
    }, "route-token", "https://cmux.example") as {
      go: { options: Record<string, unknown>; models: Record<string, { provider?: { api?: string } }> };
    };
    expect(rewritten.go.options).toEqual({
      mode: "go",
      baseURL: "https://cmux.example/api/coderouter/opencode/proxy/go",
      apiKey: "route-token",
    });
    // Nested per-model provider endpoints route through the same origin, so
    // a Cloud VM minted against any deployment stays on that deployment.
    expect(rewritten.go.models["model-1"].provider?.api).toBe(
      "https://cmux.example/api/coderouter/opencode/proxy/go",
    );
    expect(JSON.stringify(rewritten)).not.toContain("coderouter.dev");
    expect(JSON.stringify(rewritten)).not.toContain("upstream-secret");
    expect(JSON.stringify(rewritten)).not.toContain("nested-secret");
    expect(JSON.stringify(rewritten)).not.toContain("models.example.test");
  });

  test("rejects loopback and private provider targets", () => {
    expect(__test.safeProviderURL("https://api.example.com/v1")).toBe(true);
    expect(__test.safeProviderURL("http://api.example.com/v1")).toBe(false);
    expect(__test.safeProviderURL("https://127.0.0.1/v1")).toBe(false);
    expect(__test.safeProviderURL("https://10.0.0.1/v1")).toBe(false);
    expect(__test.safeProviderURL("https://192.168.1.4/v1")).toBe(false);
  });

  test("routes around an unavailable OpenCode account", async () => {
    const ids = ["busy", "healthy"];
    const selected: string[] = [];
    const result = await __test.openCodeAccount("team-1", {
      select: async (_teamId, _provider, excluded) => {
        selected.push(...(excluded ?? []));
        const id = ids.shift();
        return id
          ? { id, vaultRevision: 1, credentialExpiresAt: new Date() }
          : null;
      },
      credential: async ({ accountId }) => {
        if (accountId === "busy") throw new Error("refreshing");
        return {
          provider: "opencode-go" as const,
          accessToken: "access",
          refreshToken: "refresh",
          accountId: "provider-account",
          email: "person@example.com",
          expiresAt: Date.now() + 60_000,
        };
      },
    });
    expect(result?.account.id).toBe("healthy");
    expect(selected).toContain("busy");
  });

  test("publishes the Claude and Codex planes as opencode's own providers", () => {
    const providers = planeProviders(new Set(["anthropic-apikey", "codex"]), "route-token", "https://cmux.example");
    expect(providers).toEqual({
      anthropic: { options: { baseURL: "https://cmux.example/v1", apiKey: "route-token" } },
      openai: { options: { baseURL: "https://cmux.example/v1", apiKey: "route-token" } },
    });
    expect(planeProviders(new Set(["claude"]), "t", "https://o")).toEqual({
      anthropic: { options: { baseURL: "https://o/v1", apiKey: "t" } },
    });
    expect(planeProviders(new Set(["opencode-go"]), "t", "https://o")).toEqual({});
  });

  test("only claimable accounts count as active kinds; refreshing only on request", () => {
    const summary = (provider: CodeRouterAccountSummary["provider"], state: CodeRouterAccountSummary["state"]) => ({
      id: provider, provider, providerAccountId: provider, label: provider, state,
      credentialExpiresAt: null, lastFailureCode: null, cooldownUntil: null, activeSessions: 0,
    });
    const accounts = [summary("claude", "active"), summary("codex", "broken"), summary("openai-apikey", "refreshing")];
    expect([...activeProviderKinds(accounts)]).toEqual(["claude"]);
    expect([...activeProviderKinds(accounts, { includeRefreshing: true })]).toEqual(["claude", "openai-apikey"]);
  });
});

describe("opencode client config", () => {
  const request = new Request("https://cmux.example/api/coderouter/opencode/config", {
    headers: { authorization: "Bearer crt_token" },
  });
  const summary = (provider: CodeRouterAccountSummary["provider"]): CodeRouterAccountSummary => ({
    id: provider, provider, providerAccountId: provider, label: provider, state: "active",
    credentialExpiresAt: null, lastFailureCode: null, cooldownUntil: null, activeSessions: 0,
  });
  const goCredential = {
    provider: "opencode-go" as const, accessToken: "go-access", refreshToken: "r",
    accountId: "go-acct", email: "go@example.com", expiresAt: Date.now() + 60_000,
  };

  test("a team with only a Claude login gets opencode pointed at the Claude plane", async () => {
    let consoleFetches = 0;
    const config = createOpenCodeClientConfig({
      identity: async () => ({ teamId: "team-1", stackUserId: "u", token: "crt_token" }),
      accounts: async () => [summary("claude")],
      opencodeAccount: async () => null,
      remote: async () => {
        consoleFetches += 1;
        return {};
      },
    });
    const response = await config(request);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      provider: { anthropic: { options: { baseURL: "https://cmux.example/v1", apiKey: "crt_token" } } },
    });
    expect(consoleFetches).toBe(0);
  });

  test("an OpenCode Go catalog and the planes are served side by side", async () => {
    const config = createOpenCodeClientConfig({
      identity: async () => ({ teamId: "team-1", stackUserId: "u", token: "crt_token" }),
      accounts: async () => [summary("opencode-go"), summary("openai-apikey")],
      opencodeAccount: async () => ({ account: { id: "a", vaultRevision: 1, credentialExpiresAt: null }, credential: goCredential, attempts: 1 }),
      remote: async () => ({ go: { npm: "@ai-sdk/openai-compatible", options: { apiKey: "secret" }, models: {} } }),
    });
    const body = await (await config(request)).json() as { provider: Record<string, unknown> };
    expect(Object.keys(body.provider).sort()).toEqual(["go", "openai"]);
    expect(JSON.stringify(body)).not.toContain("secret");
  });

  test("a console outage still serves the planes", async () => {
    const config = createOpenCodeClientConfig({
      identity: async () => ({ teamId: "team-1", stackUserId: "u", token: "crt_token" }),
      accounts: async () => [summary("opencode-go"), summary("claude")],
      opencodeAccount: async () => ({ account: { id: "a", vaultRevision: 1, credentialExpiresAt: null }, credential: goCredential, attempts: 1 }),
      remote: async () => {
        throw new Error("console down");
      },
    });
    const body = await (await config(request)).json() as { provider: Record<string, unknown> };
    expect(Object.keys(body.provider)).toEqual(["anthropic"]);
  });

  test("an OpenCode-only team whose console is down is 'provider_unavailable', not 'no account'", async () => {
    const config = createOpenCodeClientConfig({
      identity: async () => ({ teamId: "team-1", stackUserId: "u", token: "crt_token" }),
      accounts: async () => [summary("opencode-go")],
      opencodeAccount: async () => ({ account: { id: "a", vaultRevision: 1, credentialExpiresAt: null }, credential: goCredential, attempts: 1 }),
      remote: async () => {
        throw new Error("console down");
      },
    });
    const response = await config(request);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "provider_unavailable" });
  });

  test("no usable account of any kind is still a 503 (the machine retries next shell)", async () => {
    const config = createOpenCodeClientConfig({
      identity: async () => ({ teamId: "team-1", stackUserId: "u", token: "crt_token" }),
      accounts: async () => [],
      opencodeAccount: async () => null,
      remote: async () => ({}),
    });
    const response = await config(request);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "no_usable_account" });
  });
});
