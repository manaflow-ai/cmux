// Relay ticket signing and verification (HMAC-SHA256, WebCrypto).
//
// Format: `v1.<b64url(claims JSON)>.<b64url(hmac(secret, "v1.<b64url claims>"))>`
// The same module runs in the web app (Node >= 18, mint side) and the worker
// and Durable Object (verify side); a verbatim copy is generated into
// web/services/mobileRelay/generated/ by tools/generate.ts.
//
// The secret is an opaque UTF-8 string of at least MIN_SECRET_CHARS shared
// only between the web app and this worker. Verification uses
// crypto.subtle.verify, which is constant-time.

import { decodeTicketClaims, TICKET_TTL_SECONDS, type RelayRole, type TicketClaims } from "./protocol";

export const TICKET_PREFIX = "v1";
export const MIN_SECRET_CHARS = 32;
/** Bound before any parsing; a real ticket is well under 1 KiB. */
export const MAX_TICKET_CHARS = 4096;

const encoder = new TextEncoder();

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> | null {
  const padded = text.replaceAll("-", "+").replaceAll("_", "/");
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
}

async function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    [usage],
  );
}

export interface MintTicketInput {
  readonly userId: string;
  readonly hostDeviceId: string;
  readonly deviceId: string;
  readonly role: RelayRole;
  readonly nowMs: number;
  readonly ttlSeconds?: number;
}

export async function mintTicket(secret: string, input: MintTicketInput): Promise<string> {
  if (secret.length < MIN_SECRET_CHARS) throw new Error("relay ticket secret too short");
  const iat = Math.floor(input.nowMs / 1000);
  const claims: TicketClaims = {
    userId: input.userId,
    hostDeviceId: input.hostDeviceId,
    deviceId: input.deviceId,
    role: input.role,
    iat,
    exp: iat + (input.ttlSeconds ?? TICKET_TTL_SECONDS),
  };
  const body = `${TICKET_PREFIX}.${base64UrlEncode(encoder.encode(JSON.stringify(claims)))}`;
  const key = await hmacKey(secret, "sign");
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
  return `${body}.${base64UrlEncode(mac)}`;
}

export type TicketVerification =
  | { readonly ok: true; readonly claims: TicketClaims }
  | { readonly ok: false; readonly error: "malformed" | "bad_signature" | "expired" | "not_yet_valid" };

export async function verifyTicket(
  secret: string,
  ticket: string,
  nowMs: number,
): Promise<TicketVerification> {
  if (secret.length < MIN_SECRET_CHARS) return { ok: false, error: "bad_signature" };
  if (ticket.length > MAX_TICKET_CHARS) return { ok: false, error: "malformed" };
  const parts = ticket.split(".");
  if (parts.length !== 3 || parts[0] !== TICKET_PREFIX || !parts[1] || !parts[2]) {
    return { ok: false, error: "malformed" };
  }
  const mac = base64UrlDecode(parts[2]);
  if (!mac) return { ok: false, error: "malformed" };
  const body = `${TICKET_PREFIX}.${parts[1]}`;
  const key = await hmacKey(secret, "verify");
  const signatureOk = await crypto.subtle.verify("HMAC", key, mac, encoder.encode(body));
  if (!signatureOk) return { ok: false, error: "bad_signature" };
  const claimsBytes = base64UrlDecode(parts[1]);
  if (!claimsBytes) return { ok: false, error: "malformed" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(claimsBytes));
  } catch {
    return { ok: false, error: "malformed" };
  }
  const decoded = decodeTicketClaims(parsed);
  if (decoded._tag === "Left") return { ok: false, error: "malformed" };
  const claims = decoded.right;
  const nowSeconds = nowMs / 1000;
  // 60s skew allowance on iat only; exp is exact.
  if (claims.iat > nowSeconds + 60) return { ok: false, error: "not_yet_valid" };
  if (claims.exp <= nowSeconds) return { ok: false, error: "expired" };
  return { ok: true, claims };
}
