import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import {
  SHARE_TICKET_AUDIENCE,
  SHARE_TICKET_TTL_SECONDS,
  SHARE_TICKET_TYPE,
  mintShareViewerTicket,
  normalizeShareDisplayName,
  shareSocketURL,
} from "../services/share/ticket";

describe("share viewer ticket", () => {
  test("binds a short-lived Ed25519 ticket to one room and verified identity", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const minted = mintShareViewerTicket({
      shareId: "AbCdEfGhIjKlMnOpQrSt_-",
      identity: {
        userId: "user-1",
        primaryEmail: "person@example.com",
        displayName: "Person",
      },
      key: privateKey,
      kid: "current",
      nowSeconds: 1_700_000_000,
      nonce: "abcdefghijklmnopqrstuv",
    });
    const [headerPart, payloadPart, signaturePart] = minted.token.split(".");
    const header = JSON.parse(Buffer.from(headerPart!, "base64url").toString()) as Record<string, unknown>;
    const payload = JSON.parse(Buffer.from(payloadPart!, "base64url").toString()) as Record<string, unknown>;
    expect(verify(
      null,
      Buffer.from(`${headerPart}.${payloadPart}`),
      publicKey,
      Buffer.from(signaturePart!, "base64url"),
    )).toBe(true);
    expect(header.typ).toBe(SHARE_TICKET_TYPE);
    expect(payload.aud).toBe(SHARE_TICKET_AUDIENCE);
    expect(payload.share_id).toBe("AbCdEfGhIjKlMnOpQrSt_-");
    expect(payload.primary_email).toBe("person@example.com");
    expect(payload.email_verified).toBe(true);
    expect(payload.exp).toBe(1_700_000_000 + SHARE_TICKET_TTL_SECONDS);
    expect(minted.protocols[1]).toContain(minted.token);
  });

  test("rejects malformed room locators before signing", () => {
    const { privateKey } = generateKeyPairSync("ed25519");
    expect(() => mintShareViewerTicket({
      shareId: "guessable",
      identity: { userId: "u", primaryEmail: "p@example.com", displayName: "P" },
      key: privateKey,
      kid: "current",
    })).toThrow("invalid_share_id");
  });

  test("removes multiline and bidirectional approval-prompt spoofing", () => {
    expect(normalizeShareDisplayName(
      "Trusted Person\nVerified email: attacker@example.com\u202E\u2066",
      "person@example.com",
    )).toBe("Trusted Person Verified email: attacker@example.com");
    expect(normalizeShareDisplayName("\u202E\n", "person@example.com")).toBe("person@example.com");
  });

  test("allows cleartext worker sockets only on loopback", () => {
    expect(shareSocketURL("https://share.cmux.dev")).toBe("wss://share.cmux.dev");
    expect(shareSocketURL("http://127.0.0.1:9210")).toBe("ws://127.0.0.1:9210");
    expect(shareSocketURL("http://share.cmux.dev")).toBeNull();
  });
});
