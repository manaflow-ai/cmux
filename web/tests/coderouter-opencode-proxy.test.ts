import { vmToken } from "./vm-authorization-fixture";
const SIGNED_TOKEN = await vmToken("vm-1", "team-1", "stack-user-1");
import { describe, expect, test } from "bun:test";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { gzipSync } from "node:zlib";
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

  // DNS rebinding: the proxy checked the provider's addresses, then fetch
  // looked the name up again and could connect to an internal address with
  // the provider credential. The checked address is pinned for the request.
  test("pins the checked provider address and connects only to it", async () => {
    const target = await __test.resolveProviderURL("https://provider.example/v1", async () => [
      { address: "2001:db8::10", family: 6 },
    ]);
    expect(target).toMatchObject({ hostname: "provider.example", pinnedAddress: "2001:db8::10", pinnedFamily: 6 });

    const seen: string[] = [];
    const server = createServer((request, response) => {
      seen.push(request.headers.host ?? "");
      request.resume();
      request.on("end", () => {
        response.writeHead(200, { "content-type": "text/plain" });
        response.end("pinned");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    try {
      // The name does not resolve at all; only the pin makes this connect.
      const url = `http://rebind.invalid:${port}/v1/chat`;
      const response = await __test.pinnedFetch({ address: "127.0.0.1", family: 4 })(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      });
      expect(response.status).toBe(200);
      await expect(response.text()).resolves.toBe("pinned");
      expect(seen).toEqual([`rebind.invalid:${port}`]);
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  // fetch decodes compressed bodies; the pinned path must too, or usage
  // accounting and the client receive gzip bytes as if they were JSON.
  test("pinned fetch decodes a compressed provider body", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "application/json", "content-encoding": "gzip" });
      response.end(gzipSync('{"usage":{"total_tokens":3}}'));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    try {
      const response = await __test.pinnedFetch({ address: "127.0.0.1", family: 4 })(
        `http://provider.invalid:${port}/v1/chat`,
        { headers: { "accept-encoding": "gzip" } },
      );
      expect(response.headers.get("content-encoding")).toBeNull();
      await expect(response.text()).resolves.toBe('{"usage":{"total_tokens":3}}');
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("pinned fetch fails the upload when the client body fails", async () => {
    let upstreamClosed!: () => void;
    const closed = new Promise<void>((resolve) => { upstreamClosed = resolve; });
    const server = createServer((request) => {
      request.on("close", () => upstreamClosed());
      request.resume();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    try {
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode("partial"));
          setTimeout(() => controller.error(new Error("client went away")), 20);
        },
      });
      const request = __test.pinnedFetch({ address: "127.0.0.1", family: 4 })(
        `http://provider.invalid:${port}/v1/chat`,
        { method: "POST", body, duplex: "half" } as RequestInit,
      );
      await expect(request).rejects.toThrow();
      await closed;
    } finally {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
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

  test("a signed token survives missing and forged VM headers", async () => {
    const missing = await openCodeClientConfig(
      configRequest({ authorization: `Bearer ${BOUND_TOKEN}` }),
      dependencies(),
    );
    expect(missing.status).toBe(200);
    await expect(missing.json()).resolves.toMatchObject({
      provider: { go: { options: { apiKey: VM_PLACEHOLDER_API_KEY } } },
    });

    const wrong = await proxyOpenCodeRequest(
      new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
        method: "POST",
        headers: {
          "authorization": `Bearer ${BOUND_TOKEN}`,
          "x-cmux-vm-id": "vm-2",
        },
        body: "{}",
      }),
      "go",
      ["chat"],
      dependencies([], { fetch: async () => new Response("ok", { status: 200 }) }),
    );
    expect(wrong.status).toBe(200);
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

describe("coderouter OpenCode with no account configured", () => {
  const TOKEN = "crt_no-account";
  function noAccountDependencies(configured: boolean) {
    const checks: string[] = [];
    return {
      checks,
      dependencies: {
        authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1", vmId: null }),
        select: async () => null,
        credential: async (): Promise<never> => {
          throw new Error("no account should be read");
        },
        remoteConfig: async (): Promise<never> => {
          throw new Error("no config should be read");
        },
        hasConfiguredAccount: async (input: { teamId: string }) => {
          checks.push(input.teamId);
          return configured;
        },
      },
    };
  }
  const terminalBody = {
    error: {
      message: "No OpenCode account is configured for this team or shared with this caller. Add one with `cr add opencode` or at coderouter.dev.",
      type: "invalid_request_error",
      code: "no_account_configured",
    },
  };
  const configRequest = () => new Request("https://cmux.example/api/coderouter/opencode/config", {
    headers: { authorization: `Bearer ${TOKEN}` },
  });
  const proxyRequest = () => new Request("https://cmux.example/api/coderouter/opencode/proxy/go/chat", {
    method: "POST",
    headers: { authorization: `Bearer ${TOKEN}`, "x-coderouter-route-token": TOKEN },
    body: "{}",
  });

  test("config answers a caller that can see no OpenCode account with the terminal 403", async () => {
    const run = noAccountDependencies(false);
    const response = await openCodeClientConfig(configRequest(), run.dependencies);
    expect(response.status).toBe(403);
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toEqual(terminalBody);
    expect(run.checks).toEqual(["team-1"]);
  });

  test("the provider proxy answers the same terminal 403", async () => {
    const run = noAccountDependencies(false);
    const response = await proxyOpenCodeRequest(proxyRequest(), "go", ["chat"], run.dependencies);
    expect(response.status).toBe(403);
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toEqual(terminalBody);
  });

  test("a caller whose accounts are all unavailable keeps a retryable 503 on both surfaces", async () => {
    const run = noAccountDependencies(true);
    const config = await openCodeClientConfig(configRequest(), run.dependencies);
    expect(config.status).toBe(503);
    expect(config.headers.get("retry-after")).not.toBeNull();
    const proxied = await proxyOpenCodeRequest(proxyRequest(), "go", ["chat"], run.dependencies);
    expect(proxied.status).toBe(503);
    expect(proxied.headers.get("retry-after")).not.toBeNull();
  });
});
