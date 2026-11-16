// The hub's side of schemas/device-hub/request-signing-vectors.json. The Linux host
// (cmux-rd-host linux_host/hub.rs) and the apps (Packages/Shared/CmuxDeviceHub)
// test against the same file, so a signer and this verifier cannot drift apart.
import { describe, expect, it } from "vitest";
import vectors from "../../../schemas/device-hub/request-signing-vectors.json";
import { canonicalRequest, lowSHex, verifyDeviceSignature } from "../src/crypto";

const encoder = new TextEncoder();

describe("request signing vectors", () => {
  for (const c of vectors.canonical) {
    it(`canonical: ${c.name}`, async () => {
      const body = c.body === null ? new Uint8Array() : encoder.encode(c.body);
      expect(await canonicalRequest(c.method, c.pathAndQuery, String(c.ts), body)).toBe(c.canonical);
    });
  }

  for (const c of vectors.signatures.cases) {
    it(`signature: ${c.name}`, async () => {
      expect(await verifyDeviceSignature(vectors.signatures.publicKey, c.signature, c.message)).toBe(c.verifies);
      expect(lowSHex(c.signature)).toBe(c.lowSHex);
    });
  }
});
