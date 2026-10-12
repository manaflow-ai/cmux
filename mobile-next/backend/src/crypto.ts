// Small WebCrypto helpers shared by the Worker and the tests.

const encoder = new TextEncoder();

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlDecode(input: string): Uint8Array {
  const b64 = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function utf8(input: string): Uint8Array {
  return encoder.encode(input);
}

export function randomBytes(length: number): Uint8Array {
  const out = new Uint8Array(length);
  crypto.getRandomValues(out);
  return out;
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", utf8(input));
  return bytesToHex(new Uint8Array(digest));
}

/** Uniform random integer in [0, max) without modulo bias. */
export function randomInt(max: number): number {
  if (max <= 0 || max > 2 ** 32) throw new RangeError("max out of range");
  const limit = Math.floor(2 ** 32 / max) * max;
  const buf = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buf);
    const v = buf[0]!;
    if (v < limit) return v % max;
  }
}

export function randomString(alphabet: string, length: number): string {
  let out = "";
  for (let i = 0; i < length; i++) out += alphabet[randomInt(alphabet.length)];
  return out;
}

/** 6-digit numeric email login code. */
export function generateEmailCode(): string {
  return randomString("0123456789", 6);
}

export const PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export const PAIRING_CODE_LENGTH = 8;

/** 8-character pairing code from an unambiguous alphabet (displayed as `XXXX-XXXX`). */
export function generatePairingCode(): string {
  return randomString(PAIRING_ALPHABET, PAIRING_CODE_LENGTH);
}

/** Normalizes a typed pairing code: uppercase, spaces and dashes removed. */
export function normalizePairingCode(raw: string): string {
  return raw.toUpperCase().replace(/[\s-]/g, "");
}

/** Opaque bearer secret with a type prefix, e.g. `cnr_...` (refresh) or `cnh_...` (host). */
export function generateToken(prefix: string): string {
  return `${prefix}_${base64UrlEncode(randomBytes(32))}`;
}

/** Constant-time comparison for equal-length secrets. */
export function timingSafeEqual(a: string, b: string): boolean {
  const ab = utf8(a);
  const bb = utf8(b);
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}
