import { z } from "zod";
import { DeviceDescriptorSchema, IdentitySchema, endpointID, identifier, revision, timestamp, type DeviceDescriptor } from "./contracts/common";
import { OperationError } from "./errors";

export const API_TICKET_SECONDS = 60 * 60;
export const RELAY_CREDENTIAL_SECONDS = 30 * 60;
export const CHALLENGE_SECONDS = 30 * 60;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

export const TicketClaimsSchema = z.strictObject({
  version: z.literal(2),
  audience: z.literal("cmux-iroh-api-v2"),
  identity: IdentitySchema,
  endpointId: endpointID,
  identityGeneration: revision,
  issuedAt: timestamp,
  expiresAt: timestamp,
  keyId: identifier,
});
export type TicketClaims = z.infer<typeof TicketClaimsSchema>;

export function encodeBase64URL(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(""))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function decodeBase64URL(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) throw new OperationError("invalid_request", 400);
  const raw = atob(value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - value.length % 4) % 4));
  const bytes = Uint8Array.from(raw, (char) => char.charCodeAt(0));
  if (encodeBase64URL(bytes) !== value) throw new OperationError("invalid_request", 400);
  return bytes;
}

/** Stable JSON for protocol values. Unsafe numbers and non-JSON values fail. */
export function canonicalJSON(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" && Number.isSafeInteger(value)) return String(value);
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON).join(",") + "]";
  if (typeof value === "object" && value !== null && Object.getPrototypeOf(value) === Object.prototype) {
    return "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonicalJSON(Reflect.get(value, key))).join(",") + "}";
  }
  throw new OperationError("invalid_request", 400);
}

export async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function identityKey(device: DeviceDescriptor): Promise<string> {
  return hash(canonicalJSON(DeviceDescriptorSchema.parse(device).identity));
}

async function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  const bytes = decodeBase64URL(secret);
  if (bytes.length < 32) throw new Error("API signing key must contain at least 32 random bytes");
  return crypto.subtle.importKey("raw", bytes, { name: "HMAC", hash: "SHA-256" }, false, [usage]);
}

export async function issueTicket(
  device: DeviceDescriptor, keyId: string, secret: string, now: number,
): Promise<{ token: string; expiresAt: number; refreshAfter: number }> {
  const claims = TicketClaimsSchema.parse({
    version: 2, audience: "cmux-iroh-api-v2", identity: device.identity,
    endpointId: device.endpointId, identityGeneration: device.identityGeneration,
    issuedAt: now, expiresAt: now + API_TICKET_SECONDS, keyId,
  });
  const body = encodeBase64URL(encoder.encode(canonicalJSON(claims)));
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret, "sign"), encoder.encode(body));
  return { token: body + "." + encodeBase64URL(new Uint8Array(signature)), expiresAt: claims.expiresAt, refreshAfter: claims.expiresAt - 300 };
}

/** Validates a signed ticket without storing an issuance row or calling Stack. */
export async function verifyTicket(
  token: string, keys: Readonly<Record<string, string>>, expectedEnvironment: string,
  expectedProject: string, now: number,
): Promise<TicketClaims> {
  try {
    if (token.length > 8192) throw new OperationError("unauthorized", 401);
    const parts = token.split(".");
    if (parts.length !== 2 || !parts[0] || !parts[1]) throw new OperationError("unauthorized", 401);
    const claims = TicketClaimsSchema.parse(JSON.parse(decoder.decode(decodeBase64URL(parts[0]))));
    const key = keys[claims.keyId];
    if (!key || !await crypto.subtle.verify("HMAC", await hmacKey(key, "verify"), decodeBase64URL(parts[1]), encoder.encode(parts[0]))) {
      throw new OperationError("unauthorized", 401);
    }
    if (claims.identity.environment !== expectedEnvironment || claims.identity.projectId !== expectedProject) {
      throw new OperationError("environment_mismatch", 403);
    }
    if (claims.issuedAt > now + 30 || claims.expiresAt - claims.issuedAt !== API_TICKET_SECONDS) throw new OperationError("unauthorized", 401);
    if (claims.expiresAt <= now) throw new OperationError("ticket_expired", 401, true);
    return claims;
  } catch (error) {
    if (error instanceof OperationError && ["ticket_expired", "environment_mismatch"].includes(error.code)) throw error;
    throw new OperationError("unauthorized", 401);
  }
}

export function challengeSigningInput(device: DeviceDescriptor, challengeId: string, nonce: string): string {
  return canonicalJSON({ purpose: "cmux-iroh-v2-enrollment", device, challengeId, nonce });
}

export function requestSigningInput(device: DeviceDescriptor, requestId: string, issuedAt: number, body: unknown): string {
  return canonicalJSON({ purpose: "cmux-iroh-v2-request", identity: device.identity, endpointId: device.endpointId, identityGeneration: device.identityGeneration, requestId, issuedAt, body });
}

export async function verifyDeviceSignature(endpoint: string, value: string, signature: string): Promise<void> {
  try {
    endpointID.parse(endpoint);
    const bytes = Uint8Array.from(endpoint.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
    const key = await crypto.subtle.importKey("raw", bytes, { name: "Ed25519" }, false, ["verify"]);
    if (!await crypto.subtle.verify("Ed25519", key, decodeBase64URL(signature), encoder.encode(value))) throw new Error("Invalid proof");
  } catch { throw new OperationError("invalid_device_proof", 403); }
}
