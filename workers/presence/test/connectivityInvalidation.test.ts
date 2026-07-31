import { describe, expect, it } from "bun:test";
import { shouldDeliverConnectivityInvalidation } from "../src/core";
import {
  isConnectivityPublisherAuthorized,
  parseConnectivityInvalidation,
} from "../src/validate";

describe("parseConnectivityInvalidation", () => {
  it("accepts a positive safe route revision", () => {
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
    expect(parseConnectivityInvalidation({ revision: 0 })).toEqual({
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

describe("isConnectivityPublisherAuthorized", () => {
  const secret = "a".repeat(64);
  const authorize = (candidate: Request, configuredSecret: string | undefined) =>
    isConnectivityPublisherAuthorized(
      candidate,
      configuredSecret,
      (expected, actual) => {
        const expectedBytes = new Uint8Array(expected);
        const actualBytes = new Uint8Array(actual);
        let difference = 0;
        for (let index = 0; index < expectedBytes.byteLength; index += 1) {
          difference |= expectedBytes[index]! ^ actualBytes[index]!;
        }
        return difference === 0;
      },
    );
  const request = (value?: string) => new Request(
    "https://presence.example/v1/connectivity/invalidate",
    {
      headers: value
        ? { "x-cmux-connectivity-publisher-secret": value }
        : {},
    },
  );

  it("requires the exact server-only capability", async () => {
    expect(await authorize(request(secret), secret)).toBe(true);
    expect(await authorize(request("b".repeat(64)), secret)).toBe(false);
    expect(await authorize(request(), secret)).toBe(false);
    expect(await authorize(request(secret), undefined)).toBe(false);
    expect(await authorize(request("short"), "short")).toBe(false);
    expect(await authorize(
      request(`${secret}extra`),
      secret,
    )).toBe(false);
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
