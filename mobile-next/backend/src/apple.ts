// Sign in with Apple identity token verification against Apple's JWKS.
import { sha256Hex } from "./crypto";
import { decodeJwt } from "./jwt";

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const JWKS_TTL_MS = 60 * 60 * 1000;
/** A token with an unknown `kid` forces at most one JWKS refetch per minute. */
const FORCED_REFETCH_INTERVAL_MS = 60 * 1000;

interface AppleJwk extends JsonWebKey {
  kid: string;
}

let cachedKeys: { keys: AppleJwk[]; fetchedAt: number } | null = null;

/** Test hook: forget the cached JWKS. */
export function resetAppleKeyCache(): void {
  cachedKeys = null;
}

async function appleKeys(force = false): Promise<AppleJwk[]> {
  const age = cachedKeys ? Date.now() - cachedKeys.fetchedAt : Infinity;
  if (cachedKeys && age < (force ? FORCED_REFETCH_INTERVAL_MS : JWKS_TTL_MS)) return cachedKeys.keys;
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error(`apple_jwks_${res.status}`);
  const body = (await res.json()) as { keys: AppleJwk[] };
  cachedKeys = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

export interface AppleIdentity {
  sub: string;
  email: string | null;
  emailVerified: boolean;
}

export class AppleTokenError extends Error {}

export async function verifyAppleIdentityToken(
  identityToken: string,
  rawNonce: string,
  audiences: string[],
  now = Math.floor(Date.now() / 1000),
): Promise<AppleIdentity> {
  const jwt = decodeJwt(identityToken);
  if (!jwt) throw new AppleTokenError("malformed token");
  if (jwt.header.alg !== "RS256" || !jwt.header.kid) throw new AppleTokenError("unsupported alg");

  let jwk = (await appleKeys()).find((k) => k.kid === jwt.header.kid);
  if (!jwk) jwk = (await appleKeys(true)).find((k) => k.kid === jwt.header.kid);
  if (!jwk) throw new AppleTokenError("unknown key");

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, jwt.signature, jwt.signingInput);
  if (!ok) throw new AppleTokenError("bad signature");

  const p = jwt.payload;
  if (p.iss !== APPLE_ISSUER) throw new AppleTokenError("bad issuer");
  const aud = Array.isArray(p.aud) ? (p.aud as string[]) : [p.aud as string];
  if (!aud.some((a) => audiences.includes(a))) throw new AppleTokenError("bad audience");
  if (typeof p.exp !== "number" || p.exp <= now) throw new AppleTokenError("expired");
  if (typeof p.sub !== "string" || !p.sub) throw new AppleTokenError("missing sub");
  if (p.nonce !== (await sha256Hex(rawNonce))) throw new AppleTokenError("bad nonce");

  const email = typeof p.email === "string" ? p.email.toLowerCase() : null;
  const emailVerified = p.email_verified === true || p.email_verified === "true";
  return { sub: p.sub, email, emailVerified };
}
