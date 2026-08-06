import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";

mock.module("../services/coderouter/repository", () => ({
  authenticateRouteToken: async () => ({
    teamId: "team-1",
    routeTokenId: "route-1",
  }),
  selectAccountForRequest: async () => ({
    id: "account-1",
    vaultRevision: 1,
  }),
  markAccountCooldown: async () => {},
  listAccounts: async () => [],
  findAccountByProviderIdentity: async () => null,
  upsertAccountMetadata: async () => {},
  withVaultLease: async (_teamId: string, operation: () => unknown) =>
    await operation(),
}));
mock.module("../services/coderouter/refresh", () => ({
  freshCredential: async () => ({
    provider: "codex",
    accessToken: "provider-access",
    accountId: "chatgpt-account",
  }),
}));

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

const { proxyCodexModels } = await import("../services/coderouter/codexProxy");

describe("coderouter models proxy", () => {
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
});
