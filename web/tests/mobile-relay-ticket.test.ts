// The generated mobile-relay protocol copies must stay functional inside the
// web app's own dependency set (they are copied from workers/mobile-relay by
// its `bun run generate`; the drift check lives in that worker's CI). This
// exercises the mint side the ticket route uses plus the verify side the
// worker applies, so a web-side effect upgrade that breaks either fails here.

import { describe, expect, test } from "bun:test";
import {
  PROTOCOL_VERSION,
  TICKET_TTL_SECONDS,
  decodeTicketClaims,
} from "../services/mobileRelay/generated/protocol";
import { mintTicket, verifyTicket } from "../services/mobileRelay/generated/ticket";

const SECRET = "0123456789abcdef0123456789abcdef";

describe("mobile relay generated protocol", () => {
  test("mint/verify roundtrip works under the web dependency set", async () => {
    const nowMs = 1_700_000_000_000;
    const ticket = await mintTicket(SECRET, {
      userId: "user-a",
      hostDeviceId: "6a4c9f1e-0000-4000-8000-00000000000a",
      deviceId: "6a4c9f1e-0000-4000-8000-00000000000b",
      role: "host",
      nowMs,
    });
    const verified = await verifyTicket(SECRET, ticket, nowMs + 1);
    expect(verified.ok).toBe(true);
    if (!verified.ok) return;
    expect(verified.claims.role).toBe("host");
    expect(verified.claims.exp - verified.claims.iat).toBe(TICKET_TTL_SECONDS);
    expect(PROTOCOL_VERSION).toBe(1);
  });

  test("claims schema rejects extra fields", () => {
    const claims = {
      userId: "u",
      hostDeviceId: "h",
      deviceId: "d",
      role: "client",
      iat: 1,
      exp: 2,
    };
    expect(decodeTicketClaims(claims)._tag).toBe("Right");
    expect(decodeTicketClaims({ ...claims, admin: true })._tag).toBe("Left");
  });
});
