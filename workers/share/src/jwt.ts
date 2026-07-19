// Offline verification of share tokens minted by the web API.
//
// Mirrors the iroh relay token system (`web/services/relay/token.ts` mints,
// the relay verifies with the public key only): compact EdDSA (Ed25519) JWTs,
// `iss=cmux`, `aud=cmux-share`, `sub=<stack user id>`, short TTL, bound to a
// specific share code via the `code` claim. The worker holds only the public
// key, so it never talks to Stack or the web app on the hot path.

export interface ShareClaims {
  /** Stack user id. */
  sub: string;
  email: string;
  /** Share code this token is valid for. */
  code: string;
  /** Host-claim connection (session creator's Mac). */
  host: boolean;
  /** True only on create-endpoint tokens: the only ones that may
   * materialize a new session. Refresh tokens reconnect, never create. */
  create: boolean;
}

export const SHARE_JWT_AUDIENCE = "cmux-share";
export const SHARE_JWT_ISSUER = "cmux";

interface JwtParts {
  signingInput: string;
  signature: Uint8Array;
  payload: Record<string, unknown>;
}

function b64urlDecode(value: string): Uint8Array | null {
  try {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const raw = atob(padded);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** Split and structurally validate a compact JWT. Pure for tests. */
export function parseJwt(token: string): JwtParts | null {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[0] || !parts[1] || !parts[2]) return null;
  const headerBytes = b64urlDecode(parts[0]);
  const payloadBytes = b64urlDecode(parts[1]);
  const signature = b64urlDecode(parts[2]);
  if (!headerBytes || !payloadBytes || !signature) return null;
  try {
    const dec = new TextDecoder();
    const header = JSON.parse(dec.decode(headerBytes)) as Record<string, unknown>;
    if (header.alg !== "EdDSA") return null;
    const payload = JSON.parse(dec.decode(payloadBytes)) as Record<string, unknown>;
    return { signingInput: `${parts[0]}.${parts[1]}`, signature, payload };
  } catch {
    return null;
  }
}

/** Claim checks separated from signature verification so they unit-test
 * without WebCrypto key material. Pure. */
export function validateClaims(
  payload: Record<string, unknown>,
  expectedCode: string,
  nowMs: number,
): ShareClaims | null {
  if (payload.iss !== SHARE_JWT_ISSUER) return null;
  if (payload.aud !== SHARE_JWT_AUDIENCE) return null;
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= nowMs) return null;
  if (typeof payload.sub !== "string" || !payload.sub) return null;
  if (typeof payload.code !== "string" || payload.code !== expectedCode) return null;
  const email = typeof payload.email === "string" ? payload.email : "";
  return {
    sub: payload.sub,
    email,
    code: payload.code,
    host: payload.host === true,
    create: payload.create === true,
  };
}

function pemToSpki(pem: string): Uint8Array | null {
  const body = pem
    .replace(/-----BEGIN PUBLIC KEY-----/, "")
    .replace(/-----END PUBLIC KEY-----/, "")
    .replace(/\s+/g, "");
  return b64urlDecode(body.replace(/\+/g, "-").replace(/\//g, "_"));
}

let cachedKey: { pem: string; key: CryptoKey } | null = null;

async function publicKey(pem: string): Promise<CryptoKey | null> {
  if (cachedKey && cachedKey.pem === pem) return cachedKey.key;
  const spki = pemToSpki(pem);
  if (!spki) return null;
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      spki.buffer as ArrayBuffer,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    cachedKey = { pem, key };
    return key;
  } catch {
    return null;
  }
}

/** Full verification: signature + claims. Returns null on any failure. */
export async function verifyShareToken(
  token: string,
  expectedCode: string,
  publicKeyPem: string,
  nowMs: number = Date.now(),
): Promise<ShareClaims | null> {
  const parts = parseJwt(token);
  if (!parts) return null;
  const key = await publicKey(publicKeyPem);
  if (!key) return null;
  const ok = await crypto.subtle.verify(
    { name: "Ed25519" },
    key,
    parts.signature.buffer as ArrayBuffer,
    new TextEncoder().encode(parts.signingInput),
  );
  if (!ok) return null;
  return validateClaims(parts.payload, expectedCode, nowMs);
}
