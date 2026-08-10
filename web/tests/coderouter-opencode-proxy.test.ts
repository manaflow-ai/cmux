import { describe, expect, test } from "bun:test";
import { __test } from "../services/coderouter/opencodeProxy";

describe("coderouter OpenCode Go proxy", () => {
  test("rewrites provider traffic through coderouter.dev without upstream secrets", () => {
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
    }, "route-token") as {
      go: { options: Record<string, unknown> };
    };
    expect(rewritten.go.options).toEqual({
      mode: "go",
      baseURL: "https://coderouter.dev/api/coderouter/opencode/proxy/go",
      apiKey: "route-token",
    });
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
