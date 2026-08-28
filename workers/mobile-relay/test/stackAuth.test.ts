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
