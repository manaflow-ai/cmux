// Verification for the account-scoped Iroh session minted by the Cloudflare
// Worker.  This module is intentionally dependency-light so it can run in the
// existing Next runtime while the Worker transitions from the compatibility
// proxy to a direct Aurora/Hyperdrive repository.

import { createHmac, timingSafeEqual } from "node:crypto";
import { env } from "../../app/env";

export const IROH_SESSION_TICKET_HEADER = "x-cmux-iroh-session-ticket";
export const IROH_SESSION_SCOPE = "iroh.control.v1";
const TICKET_VERSION = "v1";
const MAX_TICKET_CHARS = 4_096;
const MIN_SECRET_CHARS = 32;

export interface IrohSessionIdentity {
  readonly accountId: string;
  readonly sessionId: string;
  readonly epoch: number;
  readonly issuedAt: number;
  readonly expiresAt: number;
  readonly renewAt: number;
  readonly scope: typeof IROH_SESSION_SCOPE;
  readonly deviceId?: string;
  readonly appInstanceId?: string;
  readonly clientNamespace?: string;
  readonly tag?: string;
  readonly platform?: "mac" | "ios";
}

const SESSION_CONTEXT_KEYS = [
  "deviceId",
  "appInstanceId",
  "clientNamespace",
  "tag",
  "platform",
] as const;

export type IrohSessionVerification =
  | { readonly ok: true; readonly identity: IrohSessionIdentity }
  | { readonly ok: false; readonly error: "missing" | "malformed" | "invalid" | "expired" | "not_configured" };

function decodeBase64Url(value: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const decoded = Buffer.from(value, "base64url");
    if (decoded.toString("base64url") !== value) return null;
    return decoded;
  } catch {
    return null;
  }
}

function exactKeys(value: Record<string, unknown>): boolean {
  const expected = new Set([
    "v", "sid", "accountId", "scope", "iat", "exp", "renewAt", "epoch",
    ...SESSION_CONTEXT_KEYS,
  ]);
  return Object.keys(value).every((key) => expected.has(key));
}

function validString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function validInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseContext(value: Record<string, unknown>): {
  readonly deviceId: string;
  readonly appInstanceId: string;
  readonly clientNamespace: string;
  readonly tag: string;
  readonly platform: "mac" | "ios";
} | undefined | null {
  const present = SESSION_CONTEXT_KEYS.filter((key) => key in value).length;
  if (present === 0) return undefined;
  if (present !== SESSION_CONTEXT_KEYS.length) return null;
  if (!validString(value.deviceId, 255)
    || !validString(value.appInstanceId, 255)
    || !validString(value.clientNamespace, 255)
    || !/^[A-Za-z0-9._:-]{1,255}$/.test(value.clientNamespace)
    || !validString(value.tag, 255)
    || (value.platform !== "mac" && value.platform !== "ios")) {
    return null;
  }
  return {
    deviceId: value.deviceId,
    appInstanceId: value.appInstanceId,
    clientNamespace: value.clientNamespace,
    tag: value.tag,
    platform: value.platform,
  };
}

/** Verify a ticket from a Request. A present but invalid ticket is never
 * treated as an invitation to fall back to cookie/browser auth. */
export function verifyIrohSessionRequest(
  request: Request,
  options: { readonly secret?: string; readonly nowMs?: number } = {},
): IrohSessionVerification {
  const raw = request.headers.get(IROH_SESSION_TICKET_HEADER)?.trim();
  if (!raw) return { ok: false, error: "missing" };
  return verifyIrohSessionTicket(
    raw,
    options.secret ?? env.CMUX_IROH_SESSION_SIGNING_KEY,
    options.nowMs ?? Date.now(),
  );
}

// oxlint-disable-next-line complexity -- Ticket parsing keeps signature, claim, context, and time checks fail-closed in one ordered verifier.
export function verifyIrohSessionTicket(
  ticket: string,
  secret: string | undefined,
  nowMs = Date.now(),
): IrohSessionVerification {
  if (!secret || secret.length < MIN_SECRET_CHARS) {
    return { ok: false, error: "not_configured" };
  }
  if (!ticket || ticket.length > MAX_TICKET_CHARS) return { ok: false, error: "malformed" };
  const parts = ticket.split(".");
  if (parts.length !== 3 || parts[0] !== TICKET_VERSION || !parts[1] || !parts[2]) {
    return { ok: false, error: "malformed" };
  }
  const signature = decodeBase64Url(parts[2]);
  const claimsBytes = decodeBase64Url(parts[1]);
  if (!signature || !claimsBytes || signature.length !== 32) {
    return { ok: false, error: "malformed" };
  }
  const body = `${TICKET_VERSION}.${parts[1]}`;
  const expected = createHmac("sha256", secret).update(body, "utf8").digest();
  if (expected.length !== signature.length || !timingSafeEqual(expected, signature)) {
    return { ok: false, error: "invalid" };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(claimsBytes.toString("utf8"));
  } catch {
    return { ok: false, error: "malformed" };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { ok: false, error: "malformed" };
  }
  const value = parsed as Record<string, unknown>;
  if (!exactKeys(value)
    || value.v !== 1
    || value.scope !== IROH_SESSION_SCOPE
    || !validString(value.sid, 128)
    || !validString(value.accountId, 255)
    || !validInteger(value.iat)
    || !validInteger(value.exp)
    || !validInteger(value.renewAt)
    || !validInteger(value.epoch)
    || value.exp <= value.iat
    || value.renewAt < value.iat
    || value.renewAt >= value.exp) {
    return { ok: false, error: "malformed" };
  }
  const context = parseContext(value);
  if (context === null) return { ok: false, error: "malformed" };
  const nowSeconds = nowMs / 1_000;
  if (value.iat > nowSeconds + 60) return { ok: false, error: "invalid" };
  if (value.exp <= nowSeconds) return { ok: false, error: "expired" };
  return {
    ok: true,
    identity: {
      accountId: value.accountId,
      sessionId: value.sid,
      epoch: value.epoch,
      issuedAt: value.iat,
      expiresAt: value.exp,
      renewAt: value.renewAt,
      scope: IROH_SESSION_SCOPE,
      ...(context ? context : {}),
    },
  };
}
