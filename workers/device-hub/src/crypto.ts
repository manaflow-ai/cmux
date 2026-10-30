const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

export function base64Decode(input: string): Uint8Array {
  const binary = atob(input);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function base64url(bytes: Uint8Array): string {
  return base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(input: string): Uint8Array {
  return base64Decode(input.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((input.length + 3) % 4));
}

export function hex(buf: ArrayBuffer | Uint8Array): string {
  return [...(buf instanceof Uint8Array ? buf : new Uint8Array(buf))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", typeof data === "string" ? encoder.encode(data) : data));
}

// ---- Device keys: base64 X9.63 uncompressed P-256 points, raw r||s signatures ----

/** Decodes a base64 X9.63 uncompressed P-256 public key, or null if it is not one. */
export function decodeDeviceKey(b64: unknown): Uint8Array | null {
  if (typeof b64 !== "string") return null;
  let bytes: Uint8Array;
  try {
    bytes = base64Decode(b64);
  } catch {
    return null;
  }
  return bytes.length === 65 && bytes[0] === 0x04 ? bytes : null;
}

/** Validates a device key by importing it; returns false for points not on the curve. */
export async function isValidDeviceKey(b64: unknown): Promise<boolean> {
  const raw = decodeDeviceKey(b64);
  if (!raw) return false;
  try {
    await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return true;
  } catch {
    return false;
  }
}

/** ECDSA-P256-SHA256 verify of a base64 raw r||s signature with a base64 X9.63 key. */
export async function verifyDeviceSignature(keyB64: string, sigB64: string, message: string): Promise<boolean> {
  const raw = decodeDeviceKey(keyB64);
  if (!raw) return false;
  let sig: Uint8Array;
  try {
    sig = base64Decode(sigB64);
  } catch {
    return false;
  }
  if (sig.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, encoder.encode(message));
  } catch {
    return false;
  }
}

const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

/**
 * The low-S form of a base64 raw r||s P-256 signature, as hex. ECDSA is
 * malleable: (r, s) and (r, n - s) both verify, so replay checks key on this.
 * Returns null for anything that is not 64 bytes.
 */
export function lowSHex(sigB64: string): string | null {
  let sig: Uint8Array;
  try {
    sig = base64Decode(sigB64);
  } catch {
    return null;
  }
  if (sig.length !== 64) return null;
  const s = BigInt("0x" + hex(sig.slice(32)));
  const low = s > P256_N / 2n ? P256_N - s : s;
  return hex(sig.slice(0, 32)) + low.toString(16).padStart(64, "0");
}

/** Lowercase hex SHA-256 of the 65-byte signing key. */
export async function keyFingerprint(keyB64: string): Promise<string> {
  return sha256Hex(decodeDeviceKey(keyB64) ?? new Uint8Array());
}

/** The canonical string a device signs: METHOD \n path+query \n ts \n hex sha256(body) or "". */
export async function canonicalRequest(method: string, pathAndQuery: string, ts: string, body: Uint8Array): Promise<string> {
  const bodyHash = body.length === 0 ? "" : await sha256Hex(body);
  return `${method.toUpperCase()}\n${pathAndQuery}\n${ts}\n${bodyHash}`;
}

// ---- ES256 compact JWS (server session JWTs and tickets) ----

export type JwtPayload = Record<string, unknown> & { exp?: number; iat?: number; sub?: string };

export function decodeJws(token: string): { header: Record<string, unknown>; payload: JwtPayload; signingInput: string; signature: Uint8Array } {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("malformed jws");
  const [h, p, s] = parts as [string, string, string];
  return {
    header: JSON.parse(decoder.decode(base64urlDecode(h))),
    payload: JSON.parse(decoder.decode(base64urlDecode(p))),
    signingInput: `${h}.${p}`,
    signature: base64urlDecode(s),
  };
}

const keyCache = new Map<string, Promise<{ priv: CryptoKey; pub: CryptoKey }>>();

/** Imports a private P-256 JWK (JSON string) as a signing key and its public half. */
export function serverKey(jwkJson: string | undefined): Promise<{ priv: CryptoKey; pub: CryptoKey }> {
  if (!jwkJson) return Promise.reject(new Error("server key is not configured"));
  let hit = keyCache.get(jwkJson);
  if (!hit) {
    hit = (async () => {
      const jwk = JSON.parse(jwkJson) as JsonWebKey;
      const alg = { name: "ECDSA", namedCurve: "P-256" };
      const priv = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, d: jwk.d }, alg, false, ["sign"]);
      const pub = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, alg, false, ["verify"]);
      return { priv, pub };
    })();
    hit.catch(() => keyCache.delete(jwkJson));
    keyCache.set(jwkJson, hit);
  }
  return hit;
}

export async function signEs256(jwkJson: string | undefined, payload: JwtPayload, typ = "JWT"): Promise<string> {
  const { priv } = await serverKey(jwkJson);
  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", typ })));
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, encoder.encode(`${header}.${body}`));
  return `${header}.${body}.${base64url(new Uint8Array(sig))}`;
}

/** Verifies an ES256 JWS signature only (callers check claims). Null on any failure. */
export async function verifyEs256Jws(jwkJson: string | undefined, token: string): Promise<JwtPayload | null> {
  let decoded;
  try {
    decoded = decodeJws(token);
  } catch {
    return null;
  }
  if (decoded.header.alg !== "ES256" || decoded.signature.length !== 64) return null;
  try {
    const { pub } = await serverKey(jwkJson);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, decoded.signature, encoder.encode(decoded.signingInput));
    return ok ? decoded.payload : null;
  } catch {
    return null;
  }
}

/** ES256 verify against a JWK public key (Stack Auth JWKS). */
export async function verifyEs256Jwk(jwk: JsonWebKey, signingInput: string, signature: Uint8Array): Promise<boolean> {
  const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  return crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, encoder.encode(signingInput));
}

export async function verifyRs256Jwk(jwk: JsonWebKey, signingInput: string, signature: Uint8Array): Promise<boolean> {
  const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, n: jwk.n, e: jwk.e }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, encoder.encode(signingInput));
}

// ---- sealed strings (the Stack token inside the hub session) ----

const sealKeyCache = new Map<string, Promise<CryptoKey>>();

/** AES-256-GCM key derived (HKDF-SHA256) from a server secret, one per purpose. */
function sealKey(secret: string | undefined, info: string): Promise<CryptoKey> {
  if (!secret) return Promise.reject(new Error("server key is not configured"));
  const cacheKey = `${info}\n${secret}`;
  let hit = sealKeyCache.get(cacheKey);
  if (!hit) {
    hit = (async () => {
      const ikm = await crypto.subtle.importKey("raw", encoder.encode(secret), "HKDF", false, ["deriveKey"]);
      return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: encoder.encode(info) },
        ikm,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt", "decrypt"],
      );
    })();
    hit.catch(() => sealKeyCache.delete(cacheKey));
    sealKeyCache.set(cacheKey, hit);
  }
  return hit;
}

/** Encrypts `plaintext` as `<iv>.<ciphertext>` (base64url), bound to `info`. */
export async function sealString(secret: string | undefined, info: string, plaintext: string): Promise<string> {
  const key = await sealKey(secret, info);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plaintext));
  return `${base64url(iv)}.${base64url(new Uint8Array(ct))}`;
}

/** Opens a `sealString` value; null when it is malformed, tampered or sealed under another key. */
export async function openString(secret: string | undefined, info: string, sealed: string): Promise<string | null> {
  const parts = sealed.split(".");
  if (parts.length !== 2) return null;
  try {
    const key = await sealKey(secret, info);
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: base64urlDecode(parts[0]!) }, key, base64urlDecode(parts[1]!));
    return decoder.decode(pt);
  } catch {
    return null;
  }
}
