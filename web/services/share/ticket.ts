import { createPrivateKey, randomBytes, sign, type KeyObject } from "node:crypto";
import { SHARE_TICKET_PROTOCOL_PREFIX, SHARE_WEBSOCKET_PROTOCOL } from "./protocol";

export const SHARE_TICKET_ISSUER = "cmux-web";
export const SHARE_TICKET_AUDIENCE = "cmux-share";
export const SHARE_TICKET_TYPE = "cmux-share-access+jwt";
export const SHARE_TICKET_TTL_SECONDS = 60;

export type ShareTicketIdentity = {
  readonly userId: string;
  readonly primaryEmail: string;
  readonly displayName: string;
};

export type MintedShareTicket = {
  readonly token: string;
  readonly expiresAt: number;
  readonly protocols: readonly [typeof SHARE_WEBSOCKET_PROTOCOL, string];
};

let cachedKey: { pem: string; key: KeyObject } | null = null;

export function shareSigningKey(privateKeyPem = process.env.CMUX_SHARE_TICKET_PRIVATE_KEY_P8): KeyObject | null {
  const pem = privateKeyPem?.replace(/\\n/gu, "\n").trim();
  if (!pem?.includes("BEGIN")) return null;
  if (cachedKey?.pem === pem) return cachedKey.key;
  try {
    const key = createPrivateKey(pem);
    if (key.asymmetricKeyType !== "ed25519") return null;
    cachedKey = { pem, key };
    return key;
  } catch {
    return null;
  }
}

export function mintShareViewerTicket(input: {
  readonly shareId: string;
  readonly identity: ShareTicketIdentity;
  readonly key: KeyObject;
  readonly kid: string;
  readonly nowSeconds?: number;
  readonly nonce?: string;
}): MintedShareTicket {
  if (!/^[A-Za-z0-9_-]{22}$/.test(input.shareId)) throw new Error("invalid_share_id");
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(input.kid)) throw new Error("invalid_share_ticket_kid");
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1_000);
  const expiresAt = now + SHARE_TICKET_TTL_SECONDS;
  const primaryEmail = requiredString(input.identity.primaryEmail, 320);
  const header = encodeJson({ alg: "EdDSA", typ: SHARE_TICKET_TYPE, kid: input.kid });
  const claims = encodeJson({
    iss: SHARE_TICKET_ISSUER,
    aud: SHARE_TICKET_AUDIENCE,
    sub: requiredString(input.identity.userId, 256),
    share_id: input.shareId,
    primary_email: primaryEmail,
    display_name: normalizeShareDisplayName(input.identity.displayName, primaryEmail),
    email_verified: true,
    nonce: input.nonce ?? randomBytes(16).toString("base64url"),
    iat: now,
    nbf: now - 2,
    exp: expiresAt,
  });
  const signingInput = `${header}.${claims}`;
  const token = `${signingInput}.${sign(null, Buffer.from(signingInput, "ascii"), input.key).toString("base64url")}`;
  return {
    token,
    expiresAt,
    protocols: [SHARE_WEBSOCKET_PROTOCOL, `${SHARE_TICKET_PROTOCOL_PREFIX}${token}`],
  };
}

export function normalizeShareDisplayName(value: string, fallback: string): string {
  const normalized = value
    .replace(/[\u0000-\u001F\u007F-\u009F\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  return requiredString(normalized || fallback, 256);
}

export function shareSocketURL(workerOrigin = process.env.CMUX_SHARE_WORKER_URL): string | null {
  const configured = workerOrigin?.trim() || "https://share.cmux.dev";
  try {
    const url = new URL(configured);
    const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
    if (url.pathname !== "/" || url.search || url.hash || url.username || url.password ||
        (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))) return null;
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return url.origin;
  } catch {
    return null;
  }
}

function encodeJson(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function requiredString(value: string, max: number): string {
  const normalized = value.trim();
  if (!normalized || normalized.length > max) throw new Error("invalid_share_identity");
  return normalized;
}
