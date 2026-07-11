// Pure token-minting logic for the private cmux iroh relay fleet, kept separate
// from the HTTP route so it is testable without the auth/DB/telemetry graph.
//
// The web API is the token issuer: it holds the Ed25519 PRIVATE signing key
// (`CMUX_RELAY_JWT_PRIVATE_KEY_PEM`); every relay VM holds only the matching
// PUBLIC key and verifies tokens offline. A minted token is a short-TTL EdDSA
// JWT with `iss=cmux`, `aud=cmux-relay`, `sub=<user>`, and an optional
// `endpoint_id` binding (so a leaked token cannot be replayed from another key).

import { createPrivateKey, sign as edSign, type KeyObject } from "node:crypto";

export const RELAY_TOKEN_ISS = "cmux";
export const RELAY_TOKEN_AUD = "cmux-relay";
export const RELAY_TOKEN_TTL_SECONDS = 300; // short-lived; the client refreshes

// iroh EndpointId is a 32-byte Ed25519 public key, which the relay parses as
// EXACTLY 64 hex chars or its 52-char z-base-32 form. Anything else is rejected
// by the relay at connect time, so a token minted for it would be a signed-but-
// useless 200. Validate the exact encodings here so callers fail fast with 400.
const HEX_ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
// z-base-32 alphabet (ybndrfg8ejkmcpqxot1uwisza345h769); 256 bits -> 52 chars.
const ZBASE32_ENDPOINT_ID_RE = /^[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$/;

// The relay fleet the client should probe (nearest wins). Overridable via env
// (comma-separated) so the RelayMap can change without a code deploy.
const DEFAULT_RELAYS = [
  "https://usc1.relay.cmux.dev",
  "https://usw1.relay.cmux.dev",
  "https://use4.relay.cmux.dev",
  "https://euw4.relay.cmux.dev",
  "https://apne1.relay.cmux.dev",
  "https://apse1.relay.cmux.dev",
  "https://ape1.relay.cmux.dev",
];

export function relayUrls(): string[] {
  const raw = process.env.CMUX_RELAY_URLS;
  if (raw && raw.trim()) {
    const urls = raw
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    if (urls.length > 0) return urls;
  }
  return DEFAULT_RELAYS;
}

export function isValidEndpointId(value: string): boolean {
  const v = value.toLowerCase();
  return HEX_ENDPOINT_ID_RE.test(v) || ZBASE32_ENDPOINT_ID_RE.test(v);
}

// Parse the signing key once and cache it keyed on the PEM value, so
// `createPrivateKey` (not free) runs only when the configured key changes.
let cached: { pem: string; key: KeyObject } | null = null;

export function relaySigningKey(): KeyObject | null {
  const pem = process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM;
  if (!pem || !pem.includes("BEGIN")) return null;
  if (cached && cached.pem === pem) return cached.key;
  try {
    const key = createPrivateKey(pem);
    // The fleet's baked public key is Ed25519; a misconfigured RSA/EC/Ed448 key
    // would sign a token no relay can verify. Treat it as unconfigured (-> 503)
    // rather than minting an unusable token or throwing at sign time.
    if (key.asymmetricKeyType !== "ed25519") return null;
    cached = { pem, key };
    return key;
  } catch {
    return null;
  }
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

/**
 * Mint a compact EdDSA (Ed25519) JWT. Ed25519 signs the raw message (no prehash),
 * so the digest passed to `sign` is `null`. The output is byte-for-byte what
 * `jsonwebtoken`/`jose` produce and what the relay's verifier accepts.
 *
 * `endpointId` is REQUIRED: every issued token is bound to the caller's iroh
 * endpoint key so a leaked token cannot be replayed from a different key.
 */
export function mintRelayToken(params: {
  sub: string;
  endpointId: string;
  key: KeyObject;
  nowSeconds: number;
}): { token: string; expiresAt: number } {
  const { sub, endpointId, key, nowSeconds } = params;
  const expiresAt = nowSeconds + RELAY_TOKEN_TTL_SECONDS;
  const header = { alg: "EdDSA", typ: "JWT" };
  const payload: Record<string, unknown> = {
    iss: RELAY_TOKEN_ISS,
    aud: RELAY_TOKEN_AUD,
    sub,
    iat: nowSeconds,
    exp: expiresAt,
    endpoint_id: endpointId.toLowerCase(),
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(
    JSON.stringify(payload),
  )}`;
  const signature = edSign(null, Buffer.from(signingInput), key);
  return { token: `${signingInput}.${b64url(signature)}`, expiresAt };
}
