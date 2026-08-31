import { beforeEach, describe, expect, test } from "bun:test";
import { MAX_ACCESS_TOKEN_CHARS } from "../src/protocol";
import { clearStackVerdictCacheForTesting, verifyStackAccessToken } from "../src/stackAuth";

const ENV = {
  STACK_PROJECT_ID: "project-1",
  STACK_PUBLISHABLE_CLIENT_KEY: "pck_test",
};

function fetchReturning(status: number, body: unknown): { calls: Request[]; fetch: typeof fetch } {
  const calls: Request[] = [];
  const impl = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    calls.push(new Request(input as never, init));
    return new Response(JSON.stringify(body), { status });
  }) as typeof fetch;
  return { calls, fetch: impl };
}

describe("verifyStackAccessToken", () => {
  beforeEach(() => {
    clearStackVerdictCacheForTesting();
  });

  test("fails closed without project configuration", async () => {
    const { fetch } = fetchReturning(200, { id: "user-1" });
    const verdict = await verifyStackAccessToken({}, "token", Date.now(), fetch);
    expect(verdict).toEqual({ ok: false, error: "not_configured" });
  });

  test("verifies with client access type and caches the verdict", async () => {
    const { calls, fetch } = fetchReturning(200, { id: "user-1" });
    const first = await verifyStackAccessToken(ENV, "token-a", 1_000, fetch);
    expect(first).toEqual({ ok: true, userId: "user-1" });
    expect(calls.length).toBe(1);
    expect(calls[0]!.headers.get("x-stack-access-type")).toBe("client");
    expect(calls[0]!.headers.get("x-stack-project-id")).toBe("project-1");
    expect(calls[0]!.headers.get("x-stack-access-token")).toBe("token-a");
    expect(new URL(calls[0]!.url).pathname).toBe("/api/v1/users/me");

    const second = await verifyStackAccessToken(ENV, "token-a", 2_000, fetch);
    expect(second).toEqual({ ok: true, userId: "user-1" });
    expect(calls.length).toBe(1);
  });

  test("expired cache entries re-verify", async () => {
    const { calls, fetch } = fetchReturning(200, { id: "user-1" });
    await verifyStackAccessToken(ENV, "token-a", 1_000, fetch);
    await verifyStackAccessToken(ENV, "token-a", 1_000 + 61_000, fetch);
    expect(calls.length).toBe(2);
  });

  test("rejections are surfaced and never cached", async () => {
    const { calls, fetch } = fetchReturning(401, { error: "nope" });
    expect(await verifyStackAccessToken(ENV, "bad", 1_000, fetch))
      .toEqual({ ok: false, error: "invalid_token" });
    expect(await verifyStackAccessToken(ENV, "bad", 1_000, fetch))
      .toEqual({ ok: false, error: "invalid_token" });
    expect(calls.length).toBe(2);
  });

  test("stack outages report unavailable, not invalid", async () => {
    const { fetch } = fetchReturning(500, {});
    expect(await verifyStackAccessToken(ENV, "token", 1_000, fetch))
      .toEqual({ ok: false, error: "verify_unavailable" });
  });

  test("bounds the token before any network call", async () => {
    const { calls, fetch } = fetchReturning(200, { id: "user-1" });
    const oversized = "a".repeat(MAX_ACCESS_TOKEN_CHARS + 1);
    expect(await verifyStackAccessToken(ENV, oversized, 1_000, fetch))
      .toEqual({ ok: false, error: "invalid_token" });
    expect(await verifyStackAccessToken(ENV, "   ", 1_000, fetch))
      .toEqual({ ok: false, error: "invalid_token" });
    expect(calls.length).toBe(0);
  });

  test("a verified response without a user id is unavailable", async () => {
    const { fetch } = fetchReturning(200, { nope: true });
    expect(await verifyStackAccessToken(ENV, "token", 1_000, fetch))
      .toEqual({ ok: false, error: "verify_unavailable" });
  });
});

describe("verifyStackAccessToken (local JWKS path)", () => {
  const jose = require("jose") as typeof import("jose");

  async function makeSigner() {
    const { publicKey, privateKey } = await jose.generateKeyPair("ES256", { extractable: true });
    const kid = "test-kid-1";
    const jwk = { ...(await jose.exportJWK(publicKey)), kid, alg: "ES256" as const };
    return { privateKey, kid, jwks: { keys: [jwk] } };
  }

  function jwksAndUsersFetch(jwks: unknown): { calls: string[]; fetch: typeof fetch } {
    const calls: string[] = [];
    const impl = (async (input: Parameters<typeof fetch>[0]) => {
      const url = typeof input === "string" ? input : (input as Request).url;
      calls.push(url);
      if (url.includes(".well-known/jwks.json")) {
        return new Response(JSON.stringify(jwks), { status: 200 });
      }
      return new Response(JSON.stringify({ id: "fallback-user" }), { status: 200 });
    }) as typeof fetch;
    return { calls, fetch: impl };
  }

  async function signToken(
    privateKey: CryptoKey,
    kid: string,
    { aud = "project-1", sub = "user-jwt", expiresIn = 600 }: { aud?: string; sub?: string; expiresIn?: number } = {},
  ): Promise<string> {
    return await new jose.SignJWT({ sub })
      .setProtectedHeader({ alg: "ES256", kid })
      .setAudience(aud)
      .setIssuer("https://api.stack-auth.com/api/v1/projects/proj-1")
      .setIssuedAt()
      .setExpirationTime(Math.floor(Date.now() / 1000) + expiresIn)
      .sign(privateKey);
  }

  beforeEach(() => {
    clearStackVerdictCacheForTesting();
  });

  test("verifies a signed token locally without calling /users/me", async () => {
    const { privateKey, kid, jwks } = await makeSigner();
    const { calls, fetch } = jwksAndUsersFetch(jwks);
    const token = await signToken(privateKey, kid);
    expect(await verifyStackAccessToken(ENV, token, Date.now(), fetch))
      .toEqual({ ok: true, userId: "user-jwt" });
    expect(calls.filter((url) => url.includes("/users/me")).length).toBe(0);
    expect(calls.filter((url) => url.includes("jwks.json")).length).toBe(1);
    // Second call: verdict cache, no fetches at all.
    expect(await verifyStackAccessToken(ENV, token, Date.now(), fetch))
      .toEqual({ ok: true, userId: "user-jwt" });
    expect(calls.length).toBe(1);
  });

  test("rejects anonymous and restricted audiences", async () => {
    const { privateKey, kid, jwks } = await makeSigner();
    const { fetch } = jwksAndUsersFetch(jwks);
    for (const aud of ["project-1:anon", "project-1:restricted", "other-project"]) {
      const token = await signToken(privateKey, kid, { aud });
      expect(await verifyStackAccessToken(ENV, token, Date.now(), fetch))
        .toEqual({ ok: false, error: "invalid_token" });
    }
  });

  test("rejects expired tokens", async () => {
    const { privateKey, kid, jwks } = await makeSigner();
    const { fetch } = jwksAndUsersFetch(jwks);
    const token = await signToken(privateKey, kid, { expiresIn: -600 });
    expect(await verifyStackAccessToken(ENV, token, Date.now(), fetch))
      .toEqual({ ok: false, error: "invalid_token" });
  });

  test("rejects a token signed by the wrong key", async () => {
    const { jwks } = await makeSigner();
    const rogue = await makeSigner();
    const { fetch } = jwksAndUsersFetch(jwks);
    const token = await signToken(rogue.privateKey, rogue.kid, {});
    expect(await verifyStackAccessToken(ENV, token, Date.now(), fetch))
      .toEqual({ ok: false, error: "invalid_token" });
  });

  test("non-JWT tokens fall back to /users/me", async () => {
    const { jwks } = await makeSigner();
    const { calls, fetch } = jwksAndUsersFetch(jwks);
    expect(await verifyStackAccessToken(ENV, "opaque-token", Date.now(), fetch))
      .toEqual({ ok: true, userId: "fallback-user" });
    expect(calls.filter((url) => url.includes("/users/me")).length).toBe(1);
  });
});
