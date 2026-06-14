import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { makeSignedWebSocketAuthToken } from "../services/vms/drivers/wsLease";

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
});
