import { randomUUID } from "node:crypto";
import type { VerifiedCallerKey } from "./types";

// Key format duplicated from workers/coderouter/src/keys.ts; do not import across packages.
const encoder = new TextEncoder();
const keyCache = new Map<string, Promise<CryptoKey>>();

function toBase64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function fromBase64Url(value: string): Uint8Array | null {
  try {
    return new Uint8Array(Buffer.from(value, "base64url"));
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

export async function mintCallerKey(input: {
  readonly teamId: string;
  readonly kid?: string;
  readonly issuedAtSeconds?: number;
  readonly secret: string;
}): Promise<{ readonly kid: string; readonly key: string; readonly payload: VerifiedCallerKey }> {
  const payload: VerifiedCallerKey = {
    v: 1,
    kid: input.kid ?? randomUUID(),
    team: input.teamId,
    iat: input.issuedAtSeconds ?? Math.floor(Date.now() / 1000),
  };
  const payloadBytes = encoder.encode(JSON.stringify(payload));
  const payloadPart = toBase64Url(payloadBytes);
  const signed = `crk_${payloadPart}`;
  const signature = await sign(signed, input.secret);
  return { kid: payload.kid, key: `${signed}.${signature}`, payload };
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
  return isCallerPayload(parsed) ? parsed : null;
}

export function extractBearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  const match = authorization ? /^Bearer\s+(.+)$/i.exec(authorization.trim()) : null;
  return match?.[1]?.trim() || null;
}

export function verifyInternalBearer(request: Request, expected: string | undefined): boolean {
  const actual = extractBearerToken(request);
  return !!actual && !!expected && timingSafeEqualString(actual, expected);
}

export function timingSafeEqualString(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  const length = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < length; i += 1) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
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
