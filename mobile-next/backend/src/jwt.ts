// HS256 access tokens and RS256 verification helpers (WebCrypto only).
import { base64UrlDecode, base64UrlEncode, utf8 } from "./crypto";

export interface AccessClaims {
  sub: string;
  typ: "user";
  iat: number;
  exp: number;
}

const ISSUER = "cmux-next-mobile-native";

function decodeJson<T>(segment: string): T {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment))) as T;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

export async function signAccessToken(
  secret: string,
  userId: string,
  ttlSeconds: number,
  now = Math.floor(Date.now() / 1000),
): Promise<{ token: string; expiresAt: number }> {
  const header = { alg: "HS256", typ: "JWT" };
  const exp = now + ttlSeconds;
  const payload = { iss: ISSUER, sub: userId, typ: "user", iat: now, exp };
  const signingInput = `${base64UrlEncode(utf8(JSON.stringify(header)))}.${base64UrlEncode(
    utf8(JSON.stringify(payload)),
  )}`;
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), utf8(signingInput));
  return { token: `${signingInput}.${base64UrlEncode(new Uint8Array(sig))}`, expiresAt: exp };
}

/** Returns the claims of a valid access token, or null. */
export async function verifyAccessToken(
  secret: string,
  token: string,
  now = Math.floor(Date.now() / 1000),
): Promise<AccessClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts as [string, string, string];
  try {
    const header = decodeJson<{ alg?: string }>(h);
    if (header.alg !== "HS256") return null;
    const ok = await crypto.subtle.verify(
      "HMAC",
      await hmacKey(secret),
      base64UrlDecode(s),
      utf8(`${h}.${p}`),
    );
    if (!ok) return null;
    const claims = decodeJson<AccessClaims & { iss?: string }>(p);
    if (claims.iss !== ISSUER || claims.typ !== "user" || typeof claims.sub !== "string") return null;
    if (typeof claims.exp !== "number" || claims.exp <= now) return null;
    return claims;
  } catch {
    return null;
  }
}

export interface DecodedJwt {
  header: { alg?: string; kid?: string };
  payload: Record<string, unknown>;
  signingInput: Uint8Array;
  signature: Uint8Array;
}

export function decodeJwt(token: string): DecodedJwt | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts as [string, string, string];
  try {
    return {
      header: decodeJson(h),
      payload: decodeJson(p),
      signingInput: utf8(`${h}.${p}`),
      signature: base64UrlDecode(s),
    };
  } catch {
    return null;
  }
}
