import { describe, expect, it } from "bun:test";
import {
  IROH_SESSION_SCOPE,
  mintIrohSessionTicket,
  parseIrohSessionClientContext,
  sessionClientContextFromClaims,
  sessionClientNamespaceMatches,
  verifyIrohSessionTicket,
} from "../src/irohSession";

const secret = "test-session-signing-key-that-is-at-least-32-chars";

describe("Iroh session tickets", () => {
  it("round-trips the signed account claims", async () => {
    const minted = await mintIrohSessionTicket(secret, {
      accountId: "user-123",
      sessionId: "session-123",
      epoch: 4,
      nowMs: 1_700_000_000_000,
    });

    expect(minted.claims.scope).toBe(IROH_SESSION_SCOPE);
    expect(minted.claims.epoch).toBe(4);
    expect(await verifyIrohSessionTicket(secret, minted.ticket, 1_700_000_001_000)).toEqual({
      ok: true,
      claims: minted.claims,
    });
  });

  it("rejects tampering, expiry, and a missing signing key", async () => {
    const minted = await mintIrohSessionTicket(secret, {
      accountId: "user-123",
      nowMs: 1_700_000_000_000,
    });
    const parts = minted.ticket.split(".");
    parts[1] = `${parts[1]}A`;

    expect(await verifyIrohSessionTicket(secret, parts.join("."), 1_700_000_001_000))
      .toEqual({ ok: false, error: "bad_signature" });
    expect(await verifyIrohSessionTicket(secret, minted.ticket, 1_700_000_901_000))
      .toEqual({ ok: false, error: "expired" });
    expect(await verifyIrohSessionTicket(undefined, minted.ticket, 1_700_000_001_000))
      .toEqual({ ok: false, error: "not_configured" });
  });

  it("does not accept a ticket signed with a different secret", async () => {
    const minted = await mintIrohSessionTicket(secret, {
      accountId: "user-123",
      nowMs: 1_700_000_000_000,
    });
    expect(await verifyIrohSessionTicket(
      "another-session-signing-key-that-is-at-least-32-chars",
      minted.ticket,
      1_700_000_001_000,
    )).toEqual({ ok: false, error: "bad_signature" });
  });

  it("rejects unknown client-context fields instead of silently dropping them", async () => {
    expect(parseIrohSessionClientContext({ renew: true })).toBeNull();
    expect(parseIrohSessionClientContext({
      deviceId: "device",
      appInstanceId: "instance",
      clientNamespace: "namespace",
      tag: "tag",
      platform: "ios",
      extra: "must-not-be-ignored",
    })).toBeNull();
  });

  it("preserves client binding metadata when a verified ticket is renewed", async () => {
    const minted = await mintIrohSessionTicket(secret, {
      accountId: "user-123",
      nowMs: 1_700_000_000_000,
      deviceId: "device-123",
      appInstanceId: "instance-123",
      clientNamespace: "ios",
      tag: "cfio9",
      platform: "ios",
    });

    expect(sessionClientContextFromClaims(minted.claims)).toEqual({
      deviceId: "device-123",
      appInstanceId: "instance-123",
      clientNamespace: "ios",
      tag: "cfio9",
      platform: "ios",
    });
    expect(sessionClientContextFromClaims({})).toBeUndefined();

    // The renewal request carries the projected namespace header. A changed
    // namespace is still rejected by the same equality fence in the DO.
    const context = sessionClientContextFromClaims(minted.claims);
    expect(sessionClientNamespaceMatches(context, "ios")).toBe(true);
    expect(sessionClientNamespaceMatches(context, "other-ios")).toBe(false);
  });
});
