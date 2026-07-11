// Mint a short-lived relay access token for the private cmux iroh relay fleet.
//
// The web API is the token issuer: it holds the Ed25519 PRIVATE signing key
// (`CMUX_RELAY_JWT_PRIVATE_KEY_PEM`), and every relay VM holds only the matching
// PUBLIC key, which it uses to verify tokens offline (no callback to us). A
// signed-in cmux endpoint POSTs here, gets a short-TTL EdDSA JWT, and presents
// it as the iroh relay auth token; the relay's access gate checks the signature,
// `iss`/`aud`/`exp`, and (when present) that `endpoint_id` equals the
// handshake-authenticated key so a leaked token cannot be replayed elsewhere.
//
// Response also returns the fleet `relays` so the client learns the RelayMap in
// the same round-trip. If the signing key is not configured the route returns
// 503, so it is safe to ship before the key/secret is provisioned.
//
// Auth: Stack Bearer + X-Stack-Refresh-Token (same native-client path as
// /api/devices). Any signed-in user may mint a token for their own endpoints.

import { createPrivateKey, sign as edSign, type KeyObject } from "node:crypto";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ISS = "cmux";
const AUD = "cmux-relay";
const TOKEN_TTL_SECONDS = 300; // short-lived; the client refreshes before exp
const MAX_BODY_BYTES = 4 * 1024;
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

function relayUrls(): string[] {
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

// Parse the PEM once and cache it keyed on the PEM value, so `createPrivateKey`
// (not free) runs only when the configured key actually changes.
let cached: { pem: string; key: KeyObject } | null = null;

function signingKey(): KeyObject | null {
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
 * so the digest algorithm passed to `sign` is `null`. The output is byte-for-byte
 * what `jsonwebtoken`/`jose` produce and what the relay's verifier accepts.
 */
function mintRelayToken(
  sub: string,
  endpointId: string | undefined,
  key: KeyObject,
  nowSeconds: number,
): { token: string; expiresAt: number } {
  const expiresAt = nowSeconds + TOKEN_TTL_SECONDS;
  const header = { alg: "EdDSA", typ: "JWT" };
  const payload: Record<string, unknown> = {
    iss: ISS,
    aud: AUD,
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

export async function POST(request: Request): Promise<Response> {
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const key = signingKey();
  if (!key) {
    // The private signing key is not provisioned in this environment.
    return jsonResponse({ error: "relay_token_not_configured" }, 503);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }

  // Optional: bind the token to a specific iroh endpoint id (anti-replay).
  let endpointId: string | undefined;
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }
  if (raw.trim().length > 0) {
    let body: { endpointId?: unknown };
    try {
      body = JSON.parse(raw) as { endpointId?: unknown };
    } catch {
      return jsonResponse({ error: "invalid_json" }, 400);
    }
    if (body.endpointId !== undefined && body.endpointId !== null) {
      if (
        typeof body.endpointId !== "string" ||
        !ENDPOINT_ID_RE.test(body.endpointId)
      ) {
        return jsonResponse({ error: "invalid_endpoint_id" }, 400);
      }
      endpointId = body.endpointId;
    }
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const { token, expiresAt } = mintRelayToken(
    user.id,
    endpointId,
    key,
    nowSeconds,
  );
  return jsonResponse({
    token,
    expiresAt,
    ttlSeconds: TOKEN_TTL_SECONDS,
    relays: relayUrls(),
  });
}
