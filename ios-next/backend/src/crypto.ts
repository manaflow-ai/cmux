const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(input: string): Uint8Array {
  const b64 = input.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((input.length + 3) % 4);
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function randomBytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  crypto.getRandomValues(out);
  return out;
}

/** Opaque random token with a readable prefix, e.g. `rt_...`. */
export function randomToken(prefix: string, bytes = 32): string {
  return `${prefix}_${base64url(randomBytes(bytes))}`;
}

/** Short random id, e.g. `u_3k9...`. */
export function randomId(prefix: string): string {
  return randomToken(prefix, 12);
}

/** Uppercase letters and digits without 0/O, 1/I/L. */
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/** Uniformly random string over `alphabet` (rejection sampling, no modulo bias). */
export function randomCode(length: number, alphabet = CODE_ALPHABET): string {
  const limit = 256 - (256 % alphabet.length);
  let out = "";
  while (out.length < length) {
    for (const b of randomBytes(length * 2)) {
      if (b < limit && out.length < length) out += alphabet[b % alphabet.length];
    }
  }
  return out;
}

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(input: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(input)));
}

export async function sha256Base64url(input: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(input))));
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function hmacHex(secret: string, input: string): Promise<string> {
  return hex(await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(input)));
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---- JWT (HS256 sign/verify, RS256 verify) ----

export type JwtPayload = Record<string, unknown> & { exp?: number; iat?: number; sub?: string };

export function decodeJwt(token: string): { header: Record<string, unknown>; payload: JwtPayload; signingInput: string; signature: Uint8Array } {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("malformed jwt");
  const [h, p, s] = parts as [string, string, string];
  return {
    header: JSON.parse(decoder.decode(base64urlDecode(h))),
    payload: JSON.parse(decoder.decode(base64urlDecode(p))),
    signingInput: `${h}.${p}`,
    signature: base64urlDecode(s),
  };
}

export async function signHs256(secret: string, payload: JwtPayload): Promise<string> {
  const header = base64url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(`${header}.${body}`));
  return `${header}.${body}.${base64url(new Uint8Array(sig))}`;
}

/** Verifies signature and `exp`. Returns null on any failure. */
export async function verifyHs256(secret: string, token: string, nowMs: number): Promise<JwtPayload | null> {
  let decoded;
  try {
    decoded = decodeJwt(token);
  } catch {
    return null;
  }
  if (decoded.header.alg !== "HS256") return null;
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), decoded.signature, encoder.encode(decoded.signingInput));
  if (!ok) return null;
  if (typeof decoded.payload.exp !== "number" || decoded.payload.exp * 1000 <= nowMs) return null;
  return decoded.payload;
}

export async function verifyRs256(jwk: JsonWebKey, signingInput: string, signature: Uint8Array): Promise<boolean> {
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, encoder.encode(signingInput));
}
