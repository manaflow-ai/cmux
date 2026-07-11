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

// iroh EndpointId is an Ed25519 public key rendered as z-base-32 (~52 chars) or
// hex (64 chars). Validate permissively on charset/length; the relay is
// authoritative on parsing and on matching the handshake key.
const ENDPOINT_ID_RE = /^[0-9a-z]{40,120}$/i;

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
  return ENDPOINT_ID_RE.test(value);
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
 */
export function mintRelayToken(params: {
  sub: string;
  endpointId?: string;
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
  };
  if (endpointId) payload.endpoint_id = endpointId.toLowerCase();
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(
    JSON.stringify(payload),
  )}`;
  const signature = edSign(null, Buffer.from(signingInput), key);
  return { token: `${signingInput}.${b64url(signature)}`, expiresAt };
}
