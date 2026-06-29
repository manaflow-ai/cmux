import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import {
  makeReusableSignedWebSocketAuthToken,
  makeSignedWebSocketAuthToken,
} from "../services/vms/drivers/wsLease";

describe("signed WebSocket auth tokens", () => {
  test("signs compact Ed25519 attach tokens with session-scoped claims", () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const token = makeSignedWebSocketAuthToken(
      "pty",
      "vm-123",
      true,
      300,
      privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    );

    const [payloadPart, signaturePart] = token.token.split(".");
    expect(payloadPart).toBeTruthy();
    expect(signaturePart).toBeTruthy();
    expect(verify(null, Buffer.from(payloadPart), publicKey, Buffer.from(signaturePart, "base64url"))).toBe(true);

    const claims = JSON.parse(Buffer.from(payloadPart, "base64url").toString("utf8"));
    expect(claims.v).toBe(1);
    expect(claims.kind).toBe("pty");
    expect(claims.aud).toBe("vm-123");
    expect(claims.sid).toBe(token.sessionId);
    expect(claims.single_use).toBe(true);
    expect(typeof claims.jti).toBe("string");
    expect(claims.exp).toBe(token.expiresAtUnix);
  });

  test("reusable RPC signed tokens keep at least one TTL remaining near bucket boundaries", () => {
    const originalNow = Date.now;
    const { privateKey } = generateKeyPairSync("ed25519");
    const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    const ttlSeconds = 12 * 60 * 60;
    const nowUnix = ttlSeconds - 5;
    Date.now = () => nowUnix * 1000;
    try {
      const token = makeReusableSignedWebSocketAuthToken("rpc", "vm-123", ttlSeconds, privateKeyPem);
      expect(token.expiresAtUnix - nowUnix).toBeGreaterThanOrEqual(ttlSeconds);
    } finally {
      Date.now = originalNow;
    }
  });
});
