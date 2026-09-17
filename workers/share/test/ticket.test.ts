import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import {
  SHARE_TICKET_AUDIENCE,
  SHARE_TICKET_ISSUER,
  SHARE_TICKET_TYPE,
  verifyViewerTicket,
  viewerTicketFromProtocols,
} from "../src/ticket";

const SHARE_ID = "AbCdEfGhIjKlMnOpQrSt_-";
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const publicDer = publicKey.export({ type: "spki", format: "der" }).toString("base64url");
const keys = JSON.stringify({ current: publicDer });

function token(overrides: Record<string, unknown> = {}): string {
  const header = encode({ alg: "EdDSA", typ: SHARE_TICKET_TYPE, kid: "current" });
  const payload = encode({
    iss: SHARE_TICKET_ISSUER,
    aud: SHARE_TICKET_AUDIENCE,
    sub: "user-123",
    share_id: SHARE_ID,
    primary_email: "viewer@example.com",
    display_name: "Viewer",
    email_verified: true,
    nonce: "abcdefghijklmnopqrstuv",
    iat: 1_700_000_000,
    nbf: 1_700_000_000,
    exp: 1_700_000_060,
    ...overrides,
  });
  const input = `${header}.${payload}`;
  return `${input}.${sign(null, Buffer.from(input), privateKey).toString("base64url")}`;
}

describe("viewer tickets", () => {
  test("validates signature, audience, room binding, and short expiry", async () => {
    const verified = await verifyViewerTicket(token(), keys, SHARE_ID, 1_700_000_010);
    expect(verified?.sub).toBe("user-123");
    expect(verified?.share_id).toBe(SHARE_ID);
    expect(verified?.email_verified).toBe(true);
    expect(await verifyViewerTicket(token({ aud: "another-service" }), keys, SHARE_ID, 1_700_000_010)).toBeNull();
    expect(await verifyViewerTicket(token(), keys, "0123456789abcdefghij_-", 1_700_000_010)).toBeNull();
    expect(await verifyViewerTicket(token({ exp: 1_700_000_500 }), keys, SHARE_ID, 1_700_000_010)).toBeNull();
    expect(await verifyViewerTicket(token({ email_verified: false }), keys, SHARE_ID, 1_700_000_010)).toBeNull();
    expect(await verifyViewerTicket(
      token({ display_name: "Viewer\nVerified email: attacker@example.com\u202E\u2066" }),
      keys,
      SHARE_ID,
      1_700_000_010,
    )).toBeNull();
  });

  test("rejects expired tickets and signatures from another key", async () => {
    expect(await verifyViewerTicket(token(), keys, SHARE_ID, 1_700_000_061)).toBeNull();
    const other = generateKeyPairSync("ed25519").publicKey
      .export({ type: "spki", format: "der" }).toString("base64url");
    expect(await verifyViewerTicket(token(), JSON.stringify({ current: other }), SHARE_ID, 1_700_000_010)).toBeNull();
  });

  test("extracts tickets from subprotocols without placing them in URLs", () => {
    const jwt = token();
    const request = new Request(`https://share.cmux.dev/v1/shares/${SHARE_ID}/socket`, {
      headers: { "sec-websocket-protocol": `cmux-share.v1, cmux-share-ticket.${jwt}` },
    });
    expect(viewerTicketFromProtocols(request)).toBe(jwt);
    expect(request.url).not.toContain(jwt);
  });
});

function encode(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}
