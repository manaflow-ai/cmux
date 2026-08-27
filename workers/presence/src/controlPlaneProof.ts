// Ed25519 binding-request proof verification, ported to WebCrypto.
//
// Exact port of web/services/iroh/crypto.ts verifyBindingRequestSignature
// (transcript bytes, canonical base64url decode, 5-minute freshness window,
// endpointId-as-raw-public-key), returning a result instead of throwing.
//
// Phase A of the control plane authorizes via the bearer-authenticated socket
// and does NOT require this proof anywhere on the connect or message path; it
// is kept verified-and-tested here for the source-of-truth migration, when the
// DO stops proxying and must check endpoint possession itself.

const ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
const BODY_SHA256_RE = /^[0-9a-f]{64}$/;
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

/** Same freshness window the broker enforces (crypto.ts: |now - ts| > 5*60). */
export const BINDING_PROOF_FRESHNESS_WINDOW_SECONDS = 5 * 60;

export interface BindingRequestProofInput {
  readonly bindingId: string;
  readonly method: string;
  /** Request pathname with leading slashes stripped (routeHandler.ts:
   * `new URL(request.url).pathname.replace(/^\/+/, "")`). */
  readonly path: string;
  readonly timestampSeconds: number;
  /** Lowercase hex SHA-256 of the exact request body bytes (empty body hashes
   * to e3b0c442...). */
  readonly bodySha256: string;
  /** Canonical base64url (no padding) Ed25519 signature, 64 bytes decoded. */
  readonly signature: string;
  /** The endpoint's Ed25519 public key as 64 lowercase hex chars. */
  readonly endpointId: string;
  readonly nowSeconds: number;
}

export type BindingProofVerification =
  | { readonly ok: true }
  | { readonly ok: false; readonly code: "invalid_binding_request_proof" };

const INVALID: BindingProofVerification = { ok: false, code: "invalid_binding_request_proof" };

/** The exact signed bytes construction from web/services/iroh/crypto.ts
 * bindingRequestTranscript. */
export function bindingRequestTranscript(input: Omit<
  BindingRequestProofInput,
  "signature" | "endpointId" | "nowSeconds"
>): Uint8Array {
  return new TextEncoder().encode(
    `cmux/iroh/binding-request/v1\n${input.bindingId}\n${input.method}\n${input.path}\n${input.timestampSeconds}\n${input.bodySha256}`,
  );
}

/** Decode canonical base64url (no padding, re-encodes to itself) of an exact
 * byte length, mirroring crypto.ts decodeCanonicalBase64url. Null on any
 * deviation, including standard base64 with +, /, or = padding. */
export function decodeCanonicalBase64url(
  encoded: string,
  expectedLength: number,
): Uint8Array | null {
  if (!encoded || !BASE64URL_RE.test(encoded)) return null;
  const standard = encoded.replace(/-/g, "+").replace(/_/g, "/");
  const padded = standard + "=".repeat((4 - (standard.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    return null;
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  if (bytes.byteLength !== expectedLength) return null;
  // Canonicality: re-encoding must reproduce the input (rejects non-zero
  // trailing bits and overlong encodings, like the node Buffer round-trip).
  if (encodeBase64url(bytes) !== encoded) return null;
  return bytes;
}

export function encodeBase64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function endpointPublicKeyBytes(endpointId: string): Uint8Array | null {
  if (!ENDPOINT_ID_RE.test(endpointId)) return null;
  const bytes = new Uint8Array(32);
  for (let index = 0; index < 32; index += 1) {
    bytes[index] = Number.parseInt(endpointId.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

/** Verify a binding-request proof with the same semantics as the broker:
 * safe-integer timestamp inside the freshness window, hex body hash, canonical
 * 64-byte base64url signature, Ed25519 over the transcript with the endpoint's
 * own key (the endpointId IS the raw public key). Never throws. */
export async function verifyBindingRequestProof(
  input: BindingRequestProofInput,
): Promise<BindingProofVerification> {
  if (
    !Number.isSafeInteger(input.timestampSeconds)
    || Math.abs(input.nowSeconds - input.timestampSeconds) > BINDING_PROOF_FRESHNESS_WINDOW_SECONDS
    || !BODY_SHA256_RE.test(input.bodySha256)
  ) {
    return INVALID;
  }
  const signature = decodeCanonicalBase64url(input.signature, 64);
  if (signature === null) return INVALID;
  const publicKeyBytes = endpointPublicKeyBytes(input.endpointId);
  if (publicKeyBytes === null) return INVALID;
  let valid = false;
  try {
    const publicKey = await crypto.subtle.importKey(
      "raw",
      publicKeyBytes as unknown as ArrayBuffer,
      "Ed25519",
      false,
      ["verify"],
    );
    valid = await crypto.subtle.verify(
      "Ed25519",
      publicKey,
      signature as unknown as ArrayBuffer,
      bindingRequestTranscript(input) as unknown as ArrayBuffer,
    );
  } catch {
    return INVALID; // not a curve point / runtime without Ed25519
  }
  return valid ? { ok: true } : INVALID;
}

/** SHA-256 of raw bytes as lowercase hex; the body-hash leg of the transcript
 * (an empty body yields e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855). */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
