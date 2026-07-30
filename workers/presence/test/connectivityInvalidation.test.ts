import { describe, expect, it } from "bun:test";
import { shouldDeliverConnectivityInvalidation } from "../src/core";
import { parseConnectivityInvalidation } from "../src/validate";

describe("parseConnectivityInvalidation", () => {
  it("accepts a non-negative safe route revision", () => {
    expect(parseConnectivityInvalidation({ revision: 42 })).toEqual({
      ok: true,
      invalidation: { revision: 42 },
    });
  });

  it("rejects malformed, unsafe, or expanded payloads", () => {
    expect(parseConnectivityInvalidation({ revision: -1 })).toEqual({
      ok: false,
      error: "invalid_revision",
    });
    expect(parseConnectivityInvalidation({ revision: Number.MAX_SAFE_INTEGER + 1 })).toEqual({
      ok: false,
      error: "invalid_revision",
    });
    expect(parseConnectivityInvalidation({ revision: 1, routes: [] })).toEqual({
      ok: false,
      error: "invalid_request",
    });
  });
});

describe("shouldDeliverConnectivityInvalidation", () => {
  const NOW = 1_800_000_000_000;

  it("delivers only to the verified account before stream expiry", () => {
    expect(shouldDeliverConnectivityInvalidation({
      accountId: "account-a",
      expiresAt: NOW + 1,
    }, "account-a", NOW)).toBe(true);
    expect(shouldDeliverConnectivityInvalidation({
      accountId: "account-b",
      expiresAt: NOW + 1,
    }, "account-a", NOW)).toBe(false);
    expect(shouldDeliverConnectivityInvalidation({
      accountId: "account-a",
      expiresAt: NOW,
    }, "account-a", NOW)).toBe(false);
  });
});
