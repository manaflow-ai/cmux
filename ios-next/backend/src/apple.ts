import { decodeJwt, sha256Hex, timingSafeEqual, verifyRs256 } from "./crypto";
import { unauthorized } from "./errors";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const JWKS_TTL_MS = 60 * 60 * 1000;

type Jwk = JsonWebKey & { kid?: string };
let cache: { keys: Jwk[]; fetchedAt: number } | undefined;

/** Test hook. */
export function resetAppleJwksCache() {
  cache = undefined;
}

async function loadKeys(fetcher: typeof fetch, now: number, force: boolean): Promise<Jwk[]> {
  if (!force && cache && now - cache.fetchedAt < JWKS_TTL_MS) return cache.keys;
  const res = await fetcher(APPLE_JWKS_URL);
  if (!res.ok) throw new Error(`apple jwks ${res.status}`);
  const body = (await res.json()) as { keys?: Jwk[] };
  cache = { keys: body.keys ?? [], fetchedAt: now };
  return cache.keys;
}

export interface AppleClaims {
  sub: string;
  email: string | null;
  emailVerified: boolean;
}

/** Verifies a Sign in with Apple identity token (RS256, Apple JWKS). */
/**
 * Verifies a Sign in with Apple identity token (RS256, Apple JWKS). When the
 * app passes `rawNonce`, the token's `nonce` claim must equal its SHA-256 hex
 * (what the app sends to Apple) or the raw value itself.
 */
export async function verifyAppleIdentityToken(token: string, audiences: string[], fetcher: typeof fetch, now: number, rawNonce?: string): Promise<AppleClaims> {
  let decoded;
  try {
    decoded = decodeJwt(token);
  } catch {
    throw unauthorized("malformed identity token");
  }
  const { header, payload, signingInput, signature } = decoded;
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw unauthorized("unsupported identity token");
  let keys = await loadKeys(fetcher, now, false);
  let jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    keys = await loadKeys(fetcher, now, true);
    jwk = keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) throw unauthorized("unknown identity token key");
  const { kid: _kid, alg: _alg, use: _use, ...keyData } = jwk as Jwk & { use?: string };
  if (!(await verifyRs256(keyData, signingInput, signature))) throw unauthorized("bad identity token signature");
  if (payload.iss !== APPLE_ISSUER) throw unauthorized("bad identity token issuer");
  const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!aud.some((a) => typeof a === "string" && audiences.includes(a))) throw unauthorized("bad identity token audience");
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= now) throw unauthorized("identity token expired");
  if (typeof payload.sub !== "string" || !payload.sub) throw unauthorized("identity token has no subject");
  if (rawNonce !== undefined) {
    const claim = typeof payload.nonce === "string" ? payload.nonce : "";
    if (!timingSafeEqual(claim, await sha256Hex(rawNonce)) && !timingSafeEqual(claim, rawNonce)) throw unauthorized("identity token nonce mismatch");
  }
  const email = typeof payload.email === "string" ? payload.email : null;
  const verified = payload.email_verified === true || payload.email_verified === "true";
  return { sub: payload.sub, email, emailVerified: Boolean(email) && verified };
}
