import { describe, expect, test } from "bun:test";
import { decryptEnvelopeSecret, encryptEnvelopeForTests } from "../src/secrets";

describe("secret envelopes", () => {
  test("decrypts crv1 envelopes and rejects tampering", async () => {
    const key = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
    const envelope = await encryptEnvelopeForTests("provider-secret", key, new Uint8Array(12).fill(3));
    await expect(decryptEnvelopeSecret(envelope, key)).resolves.toBe("provider-secret");
    await expect(decryptEnvelopeSecret(`${envelope.slice(0, -1)}A`, key)).resolves.toBeNull();
    await expect(decryptEnvelopeSecret(envelope, undefined)).resolves.toBeNull();
  });
});
