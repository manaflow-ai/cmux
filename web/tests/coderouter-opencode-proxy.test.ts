import { vmToken } from "./vm-authorization-fixture";
const SIGNED_TOKEN = await vmToken("vm-1", "team-1", "stack-user-1");
import { describe, expect, test } from "bun:test";
import {
  __test,
  OPENCODE_PLANE_OPENAI_MODELS,
  openCodeClientConfig,
  openCodePlaneConfig,
  proxyOpenCodeRequest,
  type OpenCodePlaneAccounts,
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
    expect(__test.safeProviderURL("https://169.254.169.254/v1")).toBe(false);
    expect(__test.safeProviderURL("https://100.64.0.1/v1")).toBe(false);
    expect(__test.safeProviderURL("https://[fe80::1]/v1")).toBe(false);
    expect(__test.safeProviderURL("https://[fd00::1]/v1")).toBe(false);
    expect(__test.safeProviderURL("https://[::ffff:127.0.0.1]/v1")).toBe(false);
  });

  test("rejects provider hostnames that resolve to private addresses", async () => {
    await expect(__test.resolveProviderURL("https://provider.example/v1", async () => [
      { address: "169.254.169.254", family: 4 },
    ])).resolves.toBeNull();
    await expect(__test.resolveProviderURL("https://provider.example/v1", async () => [
      { address: "2001:db8::10", family: 6 },
    ])).resolves.toMatchObject({ hostname: "provider.example" });
  });

  test("routes around an unavailable OpenCode account", async () => {
    const ids = ["busy", "healthy"];
    const selected: string[] = [];
    const result = await __test.openCodeAccount("team-1", {
      select: async (_teamId, _provider, excluded) => {
        selected.push(...(excluded ?? []));
        const id = ids.shift();
        return id
          ? { id, provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: new Date() }
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
  const BOUND_TOKEN = SIGNED_TOKEN;
  const CLI_TOKEN = "crt_cli-token";

  function dependencies(
    authenticated: string[] = [],
    overrides: {
      fetch?: typeof fetch;
      resolveProviderURL?: (value: string) => Promise<URL | null>;
    } = {},
  ) {
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
        provider: "codex" as const,
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
      resolveProviderURL: async (value: string) => new URL(value),
      ...overrides,
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
        "x-cmux-authorization": `Bearer ${BOUND_TOKEN}`,
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

  test("rejects a provider hostname when DNS resolves it to a private address", async () => {
    const response = await proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        headers: {
          authorization: `Bearer ${CLI_TOKEN}`,
          "x-coderouter-route-token": CLI_TOKEN,
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      dependencies([], {
        resolveProviderURL: async (value: string) => __test.resolveProviderURL(
          value,
          async () => [{ address: "100.64.0.1", family: 4 }],
        ),
      }),
    );
    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toMatchObject({ error: "invalid_provider" });
  });

  test("propagates caller cancellation to the OpenCode upstream", async () => {
    const controller = new AbortController();
    let upstreamSignal: AbortSignal | null | undefined;
    let resolveFetchStarted!: () => void;
    const fetchStarted = new Promise<void>((resolve) => {
      resolveFetchStarted = resolve;
    });
    const pending = proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        signal: controller.signal,
        headers: {
          authorization: `Bearer ${CLI_TOKEN}`,
          "x-coderouter-route-token": CLI_TOKEN,
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      dependencies([], {
        fetch: async (_input, init) => {
          upstreamSignal = init?.signal;
          resolveFetchStarted();
          return await new Promise<Response>((_resolve, reject) => {
            if (init?.signal?.aborted) {
              reject(init.signal.reason);
              return;
            }
            init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
          });
        },
      }),
    );
    await fetchStarted;
    controller.abort(new DOMException("client disconnected", "AbortError"));
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(upstreamSignal?.aborted).toBe(true);
  });

  test("bounds OpenCode account selection to the request failover deadline and aborts it", async () => {
    let selectionSignal: AbortSignal | undefined;
    const stalledSelect: ReturnType<typeof dependencies>["select"] = async (...args) => {
      selectionSignal = (args as readonly unknown[])[3] as AbortSignal | undefined;
      return await new Promise<never>(() => undefined);
    };
    const response = await proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        headers: {
          authorization: `Bearer ${CLI_TOKEN}`,
          "x-coderouter-route-token": CLI_TOKEN,
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      { ...dependencies(), select: stalledSelect },
      {
        now: () => 0,
        upstreamHeadersBudgetMs: 30,
        upstreamHeadersTimeoutMs: 10,
      },
    );
    expect(response.status).toBe(503);
    expect(selectionSignal).toBeDefined();
    expect(selectionSignal?.aborted).toBe(true);
  });

  test("bounds OpenCode remote configuration to the request failover deadline", async () => {
    let configSignal: AbortSignal | undefined;
    const stalledRemoteConfig: ReturnType<typeof dependencies>["remoteConfig"] = async (...args) => {
      configSignal = (args as readonly unknown[])[1] as AbortSignal | undefined;
      return await new Promise<never>(() => undefined);
    };
    const response = await proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        headers: {
          authorization: `Bearer ${CLI_TOKEN}`,
          "x-coderouter-route-token": CLI_TOKEN,
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      { ...dependencies(), remoteConfig: stalledRemoteConfig },
      {
        now: () => 0,
        upstreamHeadersBudgetMs: 30,
        upstreamHeadersTimeoutMs: 10,
      },
    );
    expect(response.status).toBe(502);
    expect(configSignal).toBeDefined();
    expect(configSignal?.aborted).toBe(true);
  });
});

describe("coderouter OpenCode config without an OpenCode Go account", () => {
  const CLI_TOKEN = "crt_cli-token";
  const BOUND_TOKEN = SIGNED_TOKEN;
  const NONE: OpenCodePlaneAccounts = { responses: [], claude: [] };
  const CODEX: OpenCodePlaneAccounts = { responses: [{ provider: "codex", state: "active" }], claude: [] };

  function dependencies(accounts: OpenCodePlaneAccounts | Error, seen: string[] = []) {
    return {
      authenticate: async (token: string) =>
        token === CLI_TOKEN || token === BOUND_TOKEN
          ? { teamId: "team-1", stackUserId: "stack-user-1", vmId: token === BOUND_TOKEN ? "vm-1" : null }
          : null,
      select: async () => null,
      credential: async () => { throw new Error("no account, no credential"); },
      remoteConfig: async () => { throw new Error("no account, no Go catalog"); },
      planeAccounts: async (teamId: string) => {
        seen.push(teamId);
        if (accounts instanceof Error) throw accounts;
        return accounts;
      },
    };
  }

  const cliRequest = () => new Request("https://cmux.example/api/coderouter/opencode/config", {
    headers: { authorization: `Bearer ${CLI_TOKEN}` },
  });

  test("a team with a Responses account gets OpenCode routed through the /v1 plane", async () => {
    const seen: string[] = [];
    const response = await openCodeClientConfig(cliRequest(), dependencies(CODEX, seen));
    expect(response.status).toBe(200);
    expect(seen).toEqual(["team-1"]);
    const body = await response.json() as {
      model: string;
      provider: Record<string, { npm: string; options: Record<string, string>; whitelist?: string[]; models?: Record<string, { options: { instructions: string } }> }>;
    };
    expect(Object.keys(body.provider)).toEqual(["openai"]);
    // The built-in id keeps OpenCode's own store:false and max_output_tokens handling.
    expect(body.provider.openai.npm).toBe("@ai-sdk/openai");
    expect(body.provider.openai.options).toEqual({ baseURL: "https://cmux.example/v1", apiKey: CLI_TOKEN });
    expect(body.provider.openai.whitelist).toEqual(OPENCODE_PLANE_OPENAI_MODELS.map((entry) => entry.id));
    for (const model of Object.values(body.provider.openai.models ?? {})) {
      expect(model.options.instructions.length).toBeGreaterThan(0);
    }
    expect(body.model).toBe(`openai/${OPENCODE_PLANE_OPENAI_MODELS[0].id}`);
  });

  test("a VM-bound token's plane config carries only the placeholder key", async () => {
    const response = await openCodeClientConfig(
      new Request("https://cmux.example/api/coderouter/opencode/config", {
        headers: {
          authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
          "x-cmux-authorization": `Bearer ${BOUND_TOKEN}`,
          "x-cmux-vm-id": "vm-1",
        },
      }),
      dependencies({ responses: [{ provider: "openai-apikey", state: "active" }], claude: [{ kind: "anthropic_api_key", state: "active", modelIds: {} }] }),
    );
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(text).not.toContain(BOUND_TOKEN);
    const body = JSON.parse(text) as { provider: Record<string, { options: { apiKey: string; baseURL: string } }> };
    expect(Object.keys(body.provider).sort()).toEqual(["anthropic", "openai"]);
    expect(body.provider.openai.options.apiKey).toBe(VM_PLACEHOLDER_API_KEY);
    expect(body.provider.anthropic.options).toEqual({ baseURL: "https://cmux.example/v1", apiKey: VM_PLACEHOLDER_API_KEY });
  });

  test("a team with no account OpenCode can use gets a definitive, non-retryable answer", async () => {
    const response = await openCodeClientConfig(cliRequest(), dependencies(NONE));
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBeNull();
    const body = await response.json() as { error: string; retryable: boolean };
    expect(body).toMatchObject({ error: "no_usable_account", retryable: false });
  });

  test("an account lookup failure stays retryable", async () => {
    const response = await openCodeClientConfig(cliRequest(), dependencies(new Error("database down")));
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: "provider_unavailable", retryable: true });
  });

  test("only providers that will serve OpenCode are emitted", () => {
    // Broken or expired Responses accounts and OAuth-only Claude teams serve nothing.
    expect(openCodePlaneConfig({
      responses: [{ provider: "codex", state: "broken" }, { provider: "opencode-go", state: "active" }],
      claude: [{ kind: "anthropic_oauth", state: "active", modelIds: {} }, { kind: "anthropic_api_key", state: "disabled", modelIds: {} }],
    }, "key", "https://cmux.example")).toBeNull();
    // A Bedrock-only team is narrowed to the ids its map (and overrides) knows.
    const bedrock = openCodePlaneConfig({
      responses: [],
      claude: [{ kind: "bedrock", state: "active", modelIds: { "claude-custom": "us.anthropic.claude-custom-v1:0" } }],
    }, "key", "https://cmux.example") as { model: string; provider: { anthropic: { whitelist: string[] } } };
    expect(bedrock.provider.anthropic.whitelist).toContain("claude-sonnet-4-5");
    expect(bedrock.provider.anthropic.whitelist).toContain("claude-custom");
    expect(bedrock.model).toBe("anthropic/claude-sonnet-4-5");
    // An Anthropic API key serves every Anthropic model: no whitelist.
    const apiKey = openCodePlaneConfig({
      responses: [],
      claude: [{ kind: "anthropic_api_key", state: "active", modelIds: {} }, { kind: "bedrock", state: "active", modelIds: {} }],
    }, "key", "https://cmux.example") as { model?: string; provider: { anthropic: { whitelist?: string[] } } };
    expect(apiKey.provider.anthropic.whitelist).toBeUndefined();
    expect(apiKey.model).toBeUndefined();
  });
});
