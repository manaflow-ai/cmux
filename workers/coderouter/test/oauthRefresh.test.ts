import { describe, expect, test } from "bun:test";
import { buildRefreshRequest, refreshOAuthChain } from "../src/oauthRefresh";

function jwt(exp: number): string {
  return `x.${btoa(JSON.stringify({ exp })).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")}.y`;
}

describe("oauth refresh", () => {
  test("builds provider refresh requests", async () => {
    const request = buildRefreshRequest("openai", "refresh");
    expect(request.url).toBe("https://auth.openai.com/oauth/token");
    expect(await request.json()).toMatchObject({ grant_type: "refresh_token", refresh_token: "refresh" });

    const anthropic = buildRefreshRequest("anthropic", "refresh");
    expect(anthropic.headers.get("anthropic-beta")).toBe("oauth-2025-04-20");
  });

  test("requires all openai rotated token fields", async () => {
    const ok = await refreshOAuthChain(
      "openai",
      { accessToken: "old", refreshToken: "old-refresh" },
      async () => new Response(JSON.stringify({ access_token: jwt(999), refresh_token: "new-refresh", id_token: "id" })),
      0,
    );
    expect(ok.ok).toBe(true);
    if (ok.ok) expect(ok.chain.refreshToken).toBe("new-refresh");

    const bad = await refreshOAuthChain(
      "openai",
      { accessToken: "old", refreshToken: "old-refresh" },
      async () => new Response(JSON.stringify({ access_token: "new" })),
      0,
    );
    expect(bad.ok).toBe(false);
  });

  test("keeps anthropic refresh token when omitted and flags refresh-token failures", async () => {
    const ok = await refreshOAuthChain(
      "anthropic",
      { accessToken: "old", refreshToken: "old-refresh" },
      async () => new Response(JSON.stringify({ access_token: "new", expires_in: 60 })),
      1000,
    );
    expect(ok.ok).toBe(true);
    if (ok.ok) {
      expect(ok.chain.refreshToken).toBe("old-refresh");
      expect(ok.chain.expiresAt).toBe(61_000);
    }

    const bad = await refreshOAuthChain(
      "anthropic",
      { accessToken: "old", refreshToken: "bad" },
      async () => new Response('{"error":"invalid refresh_token"}', { status: 401 }),
      0,
    );
    expect(bad.ok).toBe(false);
    if (!bad.ok) expect(bad.failure.refreshTokenFailure).toBe(true);
  });
});
