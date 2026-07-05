import { timingSafeEqualString } from "./internalAuth";
import type { VerifiedCallerKey } from "./types";

const encoder = new TextEncoder();
const keyCache = new Map<string, Promise<CryptoKey>>();

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64Url(value: string): Uint8Array | null {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  const cached = keyCache.get(secret);
  if (cached) return cached;
  const promise = crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  keyCache.set(secret, promise);
  return promise;
}

async function sign(input: string, secret: string): Promise<string> {
  const key = await hmacKey(secret);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(input));
  return toBase64Url(new Uint8Array(signature));
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function extractCallerKey(headers: Headers): string | null {
  const authorization = headers.get("authorization");
  if (authorization) {
    const match = /^Bearer\s+(crk_[^\s]+)$/i.exec(authorization.trim());
    if (match?.[1]) return match[1];
  }
  const apiKey = headers.get("x-api-key")?.trim();
  return apiKey?.startsWith("crk_") ? apiKey : null;
}

export async function mintCallerKeyForTests(
  payload: VerifiedCallerKey,
  secret: string,
): Promise<string> {
  const payloadBytes = encoder.encode(JSON.stringify(payload));
  const payloadPart = toBase64Url(payloadBytes);
  const signed = `crk_${payloadPart}`;
  const signature = await sign(signed, secret);
  return `${signed}.${signature}`;
}

export async function verifyCallerKey(key: string, secret: string): Promise<VerifiedCallerKey | null> {
  if (!key.startsWith("crk_")) return null;
  const dot = key.indexOf(".");
  if (dot < 0) return null;
  const payloadPart = key.slice(4, dot);
  const signature = key.slice(dot + 1);
  if (!payloadPart || !signature) return null;
  const signed = key.slice(0, dot);
  const expected = await sign(signed, secret);
  if (!timingSafeEqualString(signature, expected)) return null;
  const payloadBytes = fromBase64Url(payloadPart);
  if (!payloadBytes) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return null;
  }
  if (!isCallerPayload(parsed)) return null;
  return parsed;
}

function isCallerPayload(value: unknown): value is VerifiedCallerKey {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    record.v === 1 &&
    typeof record.kid === "string" &&
    record.kid.length > 0 &&
    typeof record.team === "string" &&
    record.team.length > 0 &&
    typeof record.iat === "number" &&
    Number.isFinite(record.iat)
  );
}
