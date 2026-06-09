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
