import { describe, expect, test } from "bun:test";
import {
  __test,
  openCodeClientConfig,
  proxyOpenCodeRequest,
} from "../services/coderouter/opencodeProxy";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/routeTokenAuth";

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
});

describe("coderouter OpenCode Go proxy VM-bound route tokens", () => {
  const BOUND_TOKEN = "crt_bound-to-vm-1";
  const CLI_TOKEN = "crt_cli-token";

  function dependencies(authenticated: string[] = []) {
    return {
      authenticate: async (token: string) => {
        authenticated.push(token);
        if (token !== BOUND_TOKEN && token !== CLI_TOKEN) return null;
        return {
          teamId: "team-1",
          stackUserId: "stack-user-1",
          vmId: token === BOUND_TOKEN ? "vm-1" : null,
        };
      },
      select: async () => ({
        id: "acct-1",
        vaultRevision: 1,
        credentialExpiresAt: new Date(),
      }),
      credential: async () => ({
        provider: "opencode-go" as const,
        accessToken: "upstream-access",
        refreshToken: "refresh",
        accountId: "provider-account",
        email: "person@example.com",
        expiresAt: Date.now() + 60_000,
      }),
      remoteConfig: async () => ({
        go: {
          name: "OpenCode Go",
          npm: "@ai-sdk/openai-compatible",
          api: { url: "https://models.example.test/v1" },
          options: { apiKey: "upstream-secret" },
          models: { "model-1": { name: "Model One" } },
        },
      }),
    };
  }

  function configRequest(headers: Record<string, string>): Request {
    return new Request("https://cmux.example/api/coderouter/opencode/config", {
      headers,
    });
  }

  test("a bound token's config carries the placeholder key, never the token", async () => {
    const response = await openCodeClientConfig(
      configRequest({
        authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
        "x-coderouter-route-token": BOUND_TOKEN,
        "x-cmux-vm-id": "vm-1",
      }),
      dependencies(),
    );
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(text).not.toContain(BOUND_TOKEN);
    expect(text).not.toContain("upstream-secret");
    const body = JSON.parse(text) as {
      provider: { go: { options: { apiKey: string; baseURL: string } } };
    };
    expect(body.provider.go.options.apiKey).toBe(VM_PLACEHOLDER_API_KEY);
    expect(body.provider.go.options.baseURL).toBe(
      "https://cmux.example/api/coderouter/opencode/proxy/go",
    );
  });

  test("an unbound token's config still carries the token itself", async () => {
    const response = await openCodeClientConfig(
      configRequest({ authorization: `Bearer ${CLI_TOKEN}` }),
      dependencies(),
    );
    expect(response.status).toBe(200);
    const body = await response.json() as {
      provider: { go: { options: { apiKey: string } } };
    };
    expect(body.provider.go.options.apiKey).toBe(CLI_TOKEN);
  });

  test("a bound token without the matching x-cmux-vm-id is rejected", async () => {
    const missing = await openCodeClientConfig(
      configRequest({ "x-coderouter-route-token": BOUND_TOKEN }),
      dependencies(),
    );
    expect(missing.status).toBe(401);
    await expect(missing.json()).resolves.toMatchObject({
      error: "unauthorized",
      message:
        "This machine's coderouter credential does not match the machine it was issued to.",
    });

    const wrong = await proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        headers: {
          authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
          "x-coderouter-route-token": BOUND_TOKEN,
          "x-cmux-vm-id": "vm-2",
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      dependencies(),
    );
    expect(wrong.status).toBe(401);
    await expect(wrong.json()).resolves.toMatchObject({ error: "unauthorized" });
  });

  test("the placeholder API key alone is never looked up", async () => {
    const authenticated: string[] = [];
    const response = await openCodeClientConfig(
      configRequest({
        authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
        "x-cmux-vm-id": "vm-1",
      }),
      dependencies(authenticated),
    );
    expect(response.status).toBe(401);
    expect(authenticated).toEqual([]);
  });
});
