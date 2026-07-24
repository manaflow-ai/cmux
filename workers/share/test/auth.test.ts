// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.

import { describe, expect, it } from "bun:test";
import { AUTH_CACHE_TTL_MS, bearerToken, cacheDeadline, tokenExpiryMs } from "../src/auth";

function jwtWithPayload(payload: Record<string, unknown>): string {
  const b64 = btoa(JSON.stringify(payload)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `header.${b64}.signature`;
}

describe("tokenExpiryMs", () => {
  it("extracts exp (seconds) as epoch ms", () => {
    expect(tokenExpiryMs(jwtWithPayload({ exp: 1_750_000_000 }))).toBe(1_750_000_000_000);
  });

  it("returns null for opaque, malformed, or exp-less tokens", () => {
    expect(tokenExpiryMs("opaque-token")).toBeNull();
    expect(tokenExpiryMs("a.b")).toBeNull();
    expect(tokenExpiryMs("a.!!!not-base64!!!.c")).toBeNull();
    expect(tokenExpiryMs(jwtWithPayload({}))).toBeNull();
    expect(tokenExpiryMs(jwtWithPayload({ exp: "soon" }))).toBeNull();
  });
});

describe("cacheDeadline", () => {
  const now = 1_000_000;

  it("uses the TTL when the token has no expiry", () => {
    expect(cacheDeadline(now, null)).toBe(now + AUTH_CACHE_TTL_MS);
  });

  it("never extends past the token's own expiry", () => {
    expect(cacheDeadline(now, now + 5_000)).toBe(now + 5_000);
    expect(cacheDeadline(now, now + AUTH_CACHE_TTL_MS * 10)).toBe(now + AUTH_CACHE_TTL_MS);
  });
});

describe("bearerToken", () => {
  function request(headers: Record<string, string>): Request {
    return new Request("https://share.example/v1/share/create", { headers });
  }

  it("extracts the token case-insensitively and trimmed", () => {
    expect(bearerToken(request({ authorization: "Bearer tok" }))).toBe("tok");
    expect(bearerToken(request({ authorization: "bearer  tok " }))).toBe("tok");
  });

  it("returns null for missing, non-bearer, or empty credentials", () => {
    expect(bearerToken(request({}))).toBeNull();
    expect(bearerToken(request({ authorization: "Basic abc" }))).toBeNull();
    expect(bearerToken(request({ authorization: "Bearer " }))).toBeNull();
  });
});
