// Pure token-minting logic for the private cmux iroh relay fleet, kept separate
// from the HTTP route so it is testable without the auth/DB/telemetry graph.
//
// The web API is the token issuer: it holds the Ed25519 PRIVATE signing key
// (`CMUX_RELAY_JWT_PRIVATE_KEY_PEM`); every relay VM holds only the matching
// PUBLIC key and verifies tokens offline. A minted token is a short-TTL EdDSA
// JWT with `iss=cmux`, `aud=cmux-relay`, `sub=<user>`, and a required
// `endpoint_id` binding (so a leaked token cannot be replayed from another key).

import { createPrivateKey, sign as edSign, type KeyObject } from "node:crypto";
import { configuredRelayCatalog } from "./catalog";

export const RELAY_TOKEN_ISS = "cmux";
export const RELAY_TOKEN_AUD = "cmux-relay";
export const RELAY_TOKEN_TTL_SECONDS = 300; // short-lived; the client refreshes
export const RELAY_TOKEN_REFRESH_LEAD_SECONDS = 60;

export type ManagedRelayCredentialGrant = {
  readonly relayUrl: string;
  readonly token: string;
  readonly expiresAt: number;
  readonly refreshAfter: number;
  readonly ttlSeconds: number;
};

// iroh EndpointId is a 32-byte Ed25519 public key. The cmux relay parses the
// JWT claim with `EndpointId::from_str`, which (in iroh-base 1.0.0-rc.1) accepts
// EXACTLY 64-char lowercase hex OR 52-char RFC 4648 base32 (A-Z2-7,
// case-insensitive; `to_string()` emits hex). z-base-32 is a SEPARATE from_z32
// API the relay does not use, so it must NOT be accepted here. Anything the
// parser rejects would be a signed-but-useless 200, so fail fast with 400.
// (We lowercase before matching; hex is minted lowercase to satisfy HEXLOWER,
// and the relay uppercases base32 internally.)
const HEX_ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
// A 52-char RFC 4648 base32 encoding of exactly 32 bytes has 4 trailing zero
// bits, so the final symbol carries 1 data bit + 4 zero bits and can only be
// `a` (0) or `q` (16). Other final symbols have non-zero trailing bits, which
// iroh's BASE32_NOPAD decoder rejects — so require the canonical final symbol.
const BASE32_ENDPOINT_ID_RE = /^[a-z2-7]{51}[aq]$/;

/** Exact canonical fleet retained for compatibility with older route callers. */
export function relayUrls(): string[] {
  return configuredRelayCatalog().relays.map((relay) => relay.url);
}

// Note: this checks the exact encoding shape, not that the 32 bytes decode to a
// valid Ed25519 curve point (e.g. 64 `f`s pass here but are not on the curve).
// Full on-curve validation is intentionally left to the relay, which is the
// authoritative validator at connect time: the endpoint_id is the CALLER'S OWN
// iroh public key, so a legitimate client always sends a valid point, and a
// crafted-but-invalid id only yields a token bound to a key nobody holds (the
// relay requires the token's endpoint_id to equal the handshake-authenticated
// key), i.e. self-harm with no replay or availability impact. Adding a curve
// library here to reject a self-defeating input is not worth the dependency.
export function isValidEndpointId(value: string): boolean {
  const v = value.toLowerCase();
  return HEX_ENDPOINT_ID_RE.test(v) || BASE32_ENDPOINT_ID_RE.test(v);
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

/** Mint URL-keyed grants without coupling clients to a relay provider. */
export function mintManagedRelayCredentials(params: {
  readonly sub: string;
  readonly endpointId: string;
  readonly relayUrls: readonly string[];
  readonly key: KeyObject;
  readonly nowSeconds: number;
}): ManagedRelayCredentialGrant[] {
  const minted = mintRelayToken(params);
  return params.relayUrls.map((relayUrl) => ({
    relayUrl,
    token: minted.token,
    expiresAt: minted.expiresAt,
    refreshAfter: minted.expiresAt - RELAY_TOKEN_REFRESH_LEAD_SECONDS,
    ttlSeconds: RELAY_TOKEN_TTL_SECONDS,
  }));
}
