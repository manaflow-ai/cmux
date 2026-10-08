import { describe, expect, it } from "bun:test";
import {
  AUTH_CACHE_TTL_MS,
  cacheDeadline,
  requestedTeamIdFromRequest,
  resolveTeamId,
  tokenExpiryMs,
  type AuthedUser,
} from "../src/auth";

function user(overrides: Partial<AuthedUser> = {}): AuthedUser {
  return {
    id: "user-1",
    selectedTeamId: null,
    teamIds: [],
    ...overrides,
  };
}

describe("resolveTeamId", () => {
  it("rejects a requested team the caller does not belong to", () => {
    expect(resolveTeamId("team-x", user({ teamIds: ["team-a"] }))).toEqual({
      ok: false,
      error: "team_not_found",
    });
  });

  it("accepts a requested team the caller belongs to", () => {
    expect(resolveTeamId("team-a", user({ teamIds: ["team-a", "team-b"] }))).toEqual({
      ok: true,
      teamId: "team-a",
    });
  });

  it("accepts the caller's own user id as the solo-account team", () => {
    expect(resolveTeamId("user-1", user())).toEqual({ ok: true, teamId: "user-1" });
  });

  it("defaults to the selected team", () => {
    expect(resolveTeamId(null, user({ selectedTeamId: "team-s", teamIds: ["team-s", "team-b"] })))
      .toEqual({ ok: true, teamId: "team-s" });
  });

  it("defaults to the sole listed team when nothing is selected", () => {
    expect(resolveTeamId(null, user({ teamIds: ["team-only"] }))).toEqual({
      ok: true,
      teamId: "team-only",
    });
  });

  it("falls back to the user id for a solo account with no teams", () => {
    expect(resolveTeamId(null, user())).toEqual({ ok: true, teamId: "user-1" });
  });
});

describe("requestedTeamIdFromRequest", () => {
  it("prefers the X-Cmux-Team-Id header", () => {
    const request = new Request("https://presence.example/v1/presence/snapshot?teamId=query-team", {
      headers: { "x-cmux-team-id": "header-team" },
    });
    expect(requestedTeamIdFromRequest(request)).toBe("header-team");
  });

  it("falls back to the teamId query param", () => {
    const request = new Request("https://presence.example/v1/presence/snapshot?teamId=query-team");
    expect(requestedTeamIdFromRequest(request)).toBe("query-team");
  });

  it("returns null when neither is present", () => {
    expect(requestedTeamIdFromRequest(new Request("https://presence.example/"))).toBeNull();
  });
});

describe("cacheDeadline", () => {
  it("uses the TTL when the token has no parseable expiry", () => {
    expect(cacheDeadline(1_000, null)).toBe(1_000 + AUTH_CACHE_TTL_MS);
  });

  it("never caches past the token's own expiry", () => {
    expect(cacheDeadline(1_000, 2_000)).toBe(2_000);
  });
});

describe("tokenExpiryMs", () => {
  it("reads exp from a JWT payload", () => {
    const payload = btoa(JSON.stringify({ exp: 1_750_000_000 }))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    expect(tokenExpiryMs(`header.${payload}.sig`)).toBe(1_750_000_000_000);
  });

  it("returns null for opaque tokens", () => {
    expect(tokenExpiryMs("not-a-jwt")).toBeNull();
  });
});

describe("verifyRequest negative cache", () => {
  const env = {
    STACK_PROJECT_ID: "proj",
    STACK_PUBLISHABLE_CLIENT_KEY: "pk",
    STACK_API_URL: "https://stack.test",
  };

  it("verifies without a publishable key and never sends the header", async () => {
    const { verifyRequest } = await import("../src/auth");
    const realFetch = globalThis.fetch;
    const sent: Array<string | null> = [];
    const token = "opaque-keyless-token-" + Math.random().toString(36).slice(2);
    globalThis.fetch = (async (_input: unknown, init?: RequestInit) => {
      sent.push(new Headers(init?.headers).get("x-stack-publishable-client-key"));
      return Response.json({ id: "user-1", primary_email: "a@example.com" });
    }) as unknown as typeof fetch;
    try {
      const request = new Request("https://presence.test/v1/presence/snapshot", {
        headers: { authorization: `Bearer ${token}` },
      });
      const user = await verifyRequest(request, { STACK_PROJECT_ID: "proj", STACK_API_URL: "https://stack.test" });
      expect(user).not.toBeNull();
      expect(sent.length).toBeGreaterThan(0);
      expect(sent.every((value) => value === null)).toBe(true);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("does not re-hit Stack for a token it already rejected", async () => {
    const { verifyRequest } = await import("../src/auth");
    const realFetch = globalThis.fetch;
    let calls = 0;
    // Opaque (non-JWT) bearer: tokenExpiryMs is null, so the cheap expiry
    // short-circuit cannot help and only the negative cache prevents the
    // per-request Stack subrequest amplification.
    const token = "opaque-rejected-token-" + Math.random().toString(36).slice(2);
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response("unauthorized", { status: 401 });
    }) as unknown as typeof fetch;
    try {
      const make = () =>
        new Request("https://presence.test/v1/presence/snapshot", {
          headers: { authorization: `Bearer ${token}` },
        });
      expect(await verifyRequest(make(), env)).toBeNull();
      expect(await verifyRequest(make(), env)).toBeNull();
      expect(await verifyRequest(make(), env)).toBeNull();
      expect(calls).toBe(1);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  // Durable mutations (device revocation, control-socket setup) must see a
  // revoked bearer at once, not after the 60-second positive cache.
  it("a fresh verification ignores a cached success", async () => {
    const { verifyRequest } = await import("../src/auth");
    const realFetch = globalThis.fetch;
    let revoked = false;
    const token = "opaque-live-token-" + Math.random().toString(36).slice(2);
    globalThis.fetch = (async (input: string | URL | Request) => {
      if (revoked) return new Response("unauthorized", { status: 401 });
      const url = String(input);
      return Response.json(url.includes("/teams") ? { items: [] } : { id: "user-1" });
    }) as unknown as typeof fetch;
    try {
      const make = () =>
        new Request("https://presence.test/v1/control/devices/revoke", {
          headers: { authorization: `Bearer ${token}` },
        });
      expect((await verifyRequest(make(), env))?.id).toBe("user-1");
      revoked = true;
      expect((await verifyRequest(make(), env))?.id).toBe("user-1");
      expect(await verifyRequest(make(), env, { fresh: true })).toBeNull();
    } finally {
      globalThis.fetch = realFetch;
    }
  });
})
