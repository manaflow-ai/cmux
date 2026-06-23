import { describe, expect, it } from "bun:test";
import {
  AUTH_CACHE_TTL_MS,
  cacheDeadline,
  isJwtShape,
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

describe("isJwtShape", () => {
  it("accepts a three-segment JWT-shaped bearer", () => {
    expect(isJwtShape("header.payload.sig")).toBe(true);
  });

  it("rejects opaque tokens", () => {
    expect(isJwtShape("opaque-rejected-token")).toBe(false);
  });

  it("rejects tokens without exactly three segments", () => {
    expect(isJwtShape("a.b")).toBe(false);
    expect(isJwtShape("a.b.c.d")).toBe(false);
    expect(isJwtShape("")).toBe(false);
    // Three segments but one or more empty (e.g. ".." or "a..c") is not a JWT.
    expect(isJwtShape("..")).toBe(false);
    expect(isJwtShape("a..c")).toBe(false);
    expect(isJwtShape(".b.")).toBe(false);
  });
});

describe("verifyRequest", () => {
  const env = {
    STACK_PROJECT_ID: "proj",
    STACK_PUBLISHABLE_CLIENT_KEY: "pk",
    STACK_API_URL: "https://stack.test",
  };

  it("rejects an opaque bearer before any Stack subrequest", async () => {
    const { verifyRequest } = await import("../src/auth");
    const realFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response("unauthorized", { status: 401 });
    }) as unknown as typeof fetch;
    try {
      const make = () =>
        new Request("https://presence.test/v1/presence/snapshot", {
          headers: { authorization: "Bearer opaque-rejected-token" },
        });
      // Opaque (non-JWT) bearers are rejected by shape, so a flood of distinct
      // opaque values cannot amplify into 2 Stack subrequests per request.
      expect(await verifyRequest(make(), env)).toBeNull();
      expect(calls).toBe(0);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("does not re-hit Stack for a JWT it already rejected (negative cache)", async () => {
    const { verifyRequest } = await import("../src/auth");
    const realFetch = globalThis.fetch;
    let calls = 0;
    // JWT-shaped but Stack-rejected: the negative cache de-duplicates repeat
    // verifications so a hostile client replaying the same token only costs one
    // Stack round trip per TTL window.
    const payload = btoa(JSON.stringify({}))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    const token = `header.${payload}.sig`;
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
});
