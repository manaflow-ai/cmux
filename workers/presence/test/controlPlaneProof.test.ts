// Ed25519 binding-request proof verification (controlPlaneProof.ts), the
// WebCrypto port of web/services/iroh/crypto.ts verifyBindingRequestSignature.
// Keys are generated in-test via WebCrypto; no fixtures, no secrets.

import { beforeAll, describe, expect, it } from "bun:test";
import {
  bindingRequestTranscript,
  decodeCanonicalBase64url,
  encodeBase64url,
  sha256Hex,
  verifyBindingRequestProof,
} from "../src/controlPlaneProof";

const NOW_SECONDS = 1_800_000_000;
const BINDING_ID = "611ffbbb-9f60-4601-ba39-4c241b900497";
const OTHER_BINDING_ID = "e1b78ec4-7b2e-4077-88a4-ec4da794a9c6";
const EMPTY_BODY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

interface TestEndpoint {
  privateKey: CryptoKey;
  endpointId: string;
}

async function generateEndpoint(): Promise<TestEndpoint> {
  const pair = (await crypto.subtle.generateKey("Ed25519", true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const endpointId = [...raw].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return { privateKey: pair.privateKey, endpointId };
}

async function signProof(
  endpoint: TestEndpoint,
  input: {
    bindingId: string;
    method: string;
    path: string;
    timestampSeconds: number;
    bodySha256: string;
  },
): Promise<string> {
  const signature = new Uint8Array(await crypto.subtle.sign(
    "Ed25519",
    endpoint.privateKey,
    bindingRequestTranscript(input) as unknown as ArrayBuffer,
  ));
  return encodeBase64url(signature);
}

const REQUEST = {
  bindingId: BINDING_ID,
  method: "POST",
  path: "api/relay/token",
  timestampSeconds: NOW_SECONDS,
  bodySha256: EMPTY_BODY_SHA256,
};

describe("verifyBindingRequestProof", () => {
  let endpoint: TestEndpoint;
  let stranger: TestEndpoint;

  beforeAll(async () => {
    endpoint = await generateEndpoint();
    stranger = await generateEndpoint();
  });

  it("accepts a fresh, correctly signed proof", async () => {
    const signature = await signProof(endpoint, REQUEST);
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: true });
  });

  it("accepts the freshness-window boundary and rejects one second past it", async () => {
    const signature = await signProof(endpoint, REQUEST);
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS + 5 * 60,
    })).toEqual({ ok: true });
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS + 5 * 60 + 1,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });

  it("rejects an expired proof (client clock far behind)", async () => {
    const stale = { ...REQUEST, timestampSeconds: NOW_SECONDS - 6 * 60 };
    const signature = await signProof(endpoint, stale);
    expect(await verifyBindingRequestProof({
      ...stale,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });

  it("rejects a proof signed by the wrong key", async () => {
    const signature = await signProof(stranger, REQUEST);
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });

  it("rejects a proof whose bindingId was swapped after signing", async () => {
    const signature = await signProof(endpoint, REQUEST);
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      bindingId: OTHER_BINDING_ID,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });

  it("rejects a tampered body hash", async () => {
    const signature = await signProof(endpoint, REQUEST);
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      bodySha256: await sha256Hex(new TextEncoder().encode('{"endpointId":"evil"}')),
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });

  it("rejects non-canonical signature encodings and malformed inputs", async () => {
    const signature = await signProof(endpoint, REQUEST);
    const padded = `${signature}==`;
    for (const bad of [padded, signature.slice(0, 40), "", "!"]) {
      expect(await verifyBindingRequestProof({
        ...REQUEST,
        signature: bad,
        endpointId: endpoint.endpointId,
        nowSeconds: NOW_SECONDS,
      })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
    }
    // endpointId must be 64 lowercase hex chars (the raw public key).
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      signature,
      endpointId: endpoint.endpointId.toUpperCase(),
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
    // Non-integer timestamp.
    expect(await verifyBindingRequestProof({
      ...REQUEST,
      timestampSeconds: NOW_SECONDS + 0.5,
      signature,
      endpointId: endpoint.endpointId,
      nowSeconds: NOW_SECONDS,
    })).toEqual({ ok: false, code: "invalid_binding_request_proof" });
  });
});

describe("decodeCanonicalBase64url", () => {
  it("round-trips canonical encodings and rejects the rest", () => {
    const bytes = new Uint8Array(64).fill(0xff); // encodes to "__..." in base64url
    const encoded = encodeBase64url(bytes);
    expect(encoded).toContain("_");
    expect(decodeCanonicalBase64url(encoded, 64)).toEqual(bytes);
    expect(decodeCanonicalBase64url(encoded, 32)).toBeNull(); // wrong length
    expect(decodeCanonicalBase64url(`${encoded}=`, 64)).toBeNull(); // padding
    expect(decodeCanonicalBase64url(encoded.replace(/_/g, "/"), 64)).toBeNull(); // std alphabet
  });
});

describe("bindingRequestTranscript", () => {
  it("builds the exact broker signed-bytes construction", () => {
    const transcript = bindingRequestTranscript(REQUEST);
    expect(new TextDecoder().decode(transcript)).toBe(
      `cmux/iroh/binding-request/v1\n${BINDING_ID}\nPOST\napi/relay/token\n${NOW_SECONDS}\n${EMPTY_BODY_SHA256}`,
    );
  });
});
