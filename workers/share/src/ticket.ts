import { SHARE_TICKET_PROTOCOL_PREFIX, SHARE_WEBSOCKET_PROTOCOL } from "./protocol";
import { normalizeShareId } from "./state";

export const SHARE_TICKET_ISSUER = "cmux-web";
export const SHARE_TICKET_AUDIENCE = "cmux-share";
export const SHARE_TICKET_TYPE = "cmux-share-access+jwt";
export const MAX_TICKET_BYTES = 8 * 1_024;

export type ShareViewerTicket = {
  readonly iss: typeof SHARE_TICKET_ISSUER;
  readonly aud: typeof SHARE_TICKET_AUDIENCE;
  readonly sub: string;
  readonly share_id: string;
  readonly primary_email: string;
  readonly display_name: string;
  readonly email_verified: true;
  readonly nonce: string;
  readonly iat: number;
  readonly nbf: number;
  readonly exp: number;
};

type TicketHeader = {
  readonly alg: "EdDSA";
  readonly typ: typeof SHARE_TICKET_TYPE;
  readonly kid: string;
};

export function viewerTicketFromProtocols(request: Request): string | null {
  const raw = request.headers.get("sec-websocket-protocol");
  if (!raw) return null;
  const protocols = raw.split(",").map((part) => part.trim());
  if (!protocols.includes(SHARE_WEBSOCKET_PROTOCOL)) return null;
  const entry = protocols.find((part) => part.startsWith(SHARE_TICKET_PROTOCOL_PREFIX));
  const token = entry?.slice(SHARE_TICKET_PROTOCOL_PREFIX.length) ?? "";
  return token && token.length <= MAX_TICKET_BYTES ? token : null;
}

export async function verifyViewerTicket(
  token: string,
  publicKeysJson: string | undefined,
  expectedShareId: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<ShareViewerTicket | null> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((part) => !part)) return null;
  const header = decodeJson(parts[0]);
  const claims = decodeJson(parts[1]);
  if (!validHeader(header) || !validClaims(claims, expectedShareId, nowSeconds)) return null;
  const publicKey = await verificationKey(publicKeysJson, header.kid);
  if (!publicKey) return null;
  let signature: Uint8Array;
  try {
    signature = decodeBase64Url(parts[2]);
  } catch {
    return null;
  }
  if (signature.byteLength !== 64) return null;
  const valid = await crypto.subtle.verify(
    { name: "Ed25519" },
    publicKey,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  return valid ? (claims as ShareViewerTicket) : null;
}

function validHeader(value: Record<string, unknown> | null): value is TicketHeader {
  return !!value &&
    exactKeys(value, ["alg", "typ", "kid"]) &&
    value.alg === "EdDSA" &&
    value.typ === SHARE_TICKET_TYPE &&
    typeof value.kid === "string" &&
    /^[A-Za-z0-9._-]{1,64}$/.test(value.kid);
}

function validClaims(
  value: Record<string, unknown> | null,
  expectedShareId: string,
  nowSeconds: number,
): value is ShareViewerTicket {
  if (!value || !exactKeys(value, [
    "iss", "aud", "sub", "share_id", "primary_email", "display_name", "email_verified", "nonce", "iat", "nbf", "exp",
  ])) return false;
  if (
    value.iss !== SHARE_TICKET_ISSUER ||
    value.aud !== SHARE_TICKET_AUDIENCE ||
    value.share_id !== expectedShareId ||
    normalizeShareId(expectedShareId) === null ||
    !shortString(value.sub, 256) ||
    !shortString(value.primary_email, 320) ||
    !shortString(value.display_name, 256) ||
    normalizeDisplayName(value.display_name) !== value.display_name ||
    value.email_verified !== true ||
    typeof value.nonce !== "string" ||
    !/^[A-Za-z0-9_-]{22,86}$/.test(value.nonce) ||
    !integer(value.iat) || !integer(value.nbf) || !integer(value.exp)
  ) return false;
  return value.iat <= nowSeconds + 30 && value.nbf <= nowSeconds + 5 && value.exp > nowSeconds && value.exp - value.iat <= 120;
}

export function normalizeDisplayName(value: string): string {
  return value
    .replace(/[\u0000-\u001F\u007F-\u009F\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
}

async function verificationKey(keysJson: string | undefined, kid: string): Promise<CryptoKey | null> {
  if (!keysJson || keysJson.length > 32_768) return null;
  try {
    const keys = JSON.parse(keysJson) as Record<string, unknown>;
    const encoded = keys[kid];
    if (typeof encoded !== "string" || encoded.length > 1_024) return null;
    return await crypto.subtle.importKey(
      "spki",
      decodeBase64Url(encoded),
      { name: "Ed25519" },
      false,
      ["verify"],
    );
  } catch {
    return null;
  }
}

function decodeJson(encoded: string | undefined): Record<string, unknown> | null {
  if (!encoded || encoded.length > MAX_TICKET_BYTES) return null;
  try {
    const value = JSON.parse(new TextDecoder().decode(decodeBase64Url(encoded)));
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function decodeBase64Url(value: string | undefined): Uint8Array {
  if (!value || !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid base64url");
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const raw = atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
  return Uint8Array.from(raw, (character) => character.charCodeAt(0));
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const keys = Object.keys(value).sort();
  return keys.length === expected.length && keys.every((key, index) => key === [...expected].sort()[index]);
}

function shortString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function integer(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
