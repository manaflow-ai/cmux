import { describe, expect, test } from "bun:test";
import { mintTicket, verifyTicket } from "../src/ticket";
import { TICKET_TTL_SECONDS } from "../src/protocol";

const SECRET = "0123456789abcdef0123456789abcdef";
const OTHER_SECRET = "fedcba9876543210fedcba9876543210";

const input = {
  userId: "user-1",
  hostDeviceId: "6a4c9f1e-0000-4000-8000-000000000001",
  deviceId: "6a4c9f1e-0000-4000-8000-000000000002",
  role: "client" as const,
  nowMs: 1_700_000_000_000,
};

describe("relay tickets", () => {
  test("mint then verify roundtrips the claims", async () => {
    const ticket = await mintTicket(SECRET, input);
    const verified = await verifyTicket(SECRET, ticket, input.nowMs + 1000);
    expect(verified.ok).toBe(true);
    if (!verified.ok) return;
    expect(verified.claims.userId).toBe(input.userId);
    expect(verified.claims.hostDeviceId).toBe(input.hostDeviceId);
    expect(verified.claims.deviceId).toBe(input.deviceId);
    expect(verified.claims.role).toBe("client");
    expect(verified.claims.exp - verified.claims.iat).toBe(TICKET_TTL_SECONDS);
  });

  test("rejects the wrong secret", async () => {
    const ticket = await mintTicket(SECRET, input);
    const verified = await verifyTicket(OTHER_SECRET, ticket, input.nowMs);
    expect(verified).toEqual({ ok: false, error: "bad_signature" });
  });

  test("rejects a tampered claims segment", async () => {
    const ticket = await mintTicket(SECRET, input);
    const parts = ticket.split(".");
    const claims = JSON.parse(Buffer.from(parts[1]!, "base64url").toString());
    claims.role = "host";
    const forged = `${parts[0]}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.${parts[2]}`;
    const verified = await verifyTicket(SECRET, forged, input.nowMs);
    expect(verified).toEqual({ ok: false, error: "bad_signature" });
  });

  test("rejects an expired ticket", async () => {
    const ticket = await mintTicket(SECRET, input);
    const verified = await verifyTicket(SECRET, ticket, input.nowMs + (TICKET_TTL_SECONDS + 1) * 1000);
    expect(verified).toEqual({ ok: false, error: "expired" });
  });

  test("rejects a ticket issued in the future beyond skew", async () => {
    const ticket = await mintTicket(SECRET, { ...input, nowMs: input.nowMs + 10 * 60 * 1000 });
    const verified = await verifyTicket(SECRET, ticket, input.nowMs);
    expect(verified).toEqual({ ok: false, error: "not_yet_valid" });
  });

  test("rejects malformed tickets", async () => {
    for (const bad of ["", "v1", "v2.a.b", "v1..sig", `v1.${"x".repeat(5000)}.sig`]) {
      const verified = await verifyTicket(SECRET, bad, input.nowMs);
      expect(verified.ok).toBe(false);
    }
  });

  test("refuses to mint with a short secret", async () => {
    await expect(mintTicket("short", input)).rejects.toThrow();
  });
});
