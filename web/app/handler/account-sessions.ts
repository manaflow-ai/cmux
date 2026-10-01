// Saved sessions for the accounts this browser has signed in to, so the
// account chooser can switch between them without a new sign-in, like
// Gmail's account list.
//
// The sign-in service keeps one session per browser. Each account's refresh
// token is kept here instead, in one cookie that only the server reads:
// httpOnly, scoped to the /handler/accounts routes, and encrypted with a key
// derived from the server secret. Page scripts never see it, and no page
// render receives it. A token is only handed back after the service confirms
// it still belongs to the account that was picked.

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import type { NextRequest, NextResponse } from "next/server";
import { ACCOUNT_HISTORY_LIMIT } from "./sign-in-entry";

export type SavedSession = {
  /** The account's user id. */
  id: string;
  refreshToken: string;
  savedAt: number;
};

export const ACCOUNT_SESSIONS_COOKIE = "cmux-account-sessions";
export const ACCOUNT_SESSIONS_PATH = "/handler/accounts";
const ACCOUNT_SESSIONS_MAX_AGE_SECONDS = 365 * 24 * 60 * 60;
const VAULT_VERSION = "v1";

export function isAccountId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 128 && /^[A-Za-z0-9_-]+$/.test(value);
}

// MARK: The list

/** Puts the session first, replacing any older one for the same account. */
export function saveSession(sessions: SavedSession[], session: SavedSession): SavedSession[] {
  return [session, ...sessions.filter((entry) => entry.id !== session.id)].slice(0, ACCOUNT_HISTORY_LIMIT);
}

export function dropSession(sessions: SavedSession[], id: string): SavedSession[] {
  return sessions.filter((entry) => entry.id !== id);
}

export function findSession(sessions: SavedSession[], id: string): SavedSession | null {
  return sessions.find((entry) => entry.id === id) ?? null;
}

// MARK: Sealing

function vaultKey(secret: string): Buffer {
  return Buffer.from(hkdfSync("sha256", secret, "cmux-account-sessions", VAULT_VERSION, 32));
}

export function sealSessions(sessions: SavedSession[], secret: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", vaultKey(secret), iv);
  const plain = JSON.stringify(sessions.map(({ id, refreshToken, savedAt }) => [id, refreshToken, savedAt]));
  const sealed = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return `${VAULT_VERSION}.${Buffer.concat([iv, sealed, cipher.getAuthTag()]).toString("base64url")}`;
}

/** The sessions in a sealed value. Anything damaged, foreign or from an old key reads as none. */
export function openSessions(value: string | null | undefined, secret: string): SavedSession[] {
  if (!value?.startsWith(`${VAULT_VERSION}.`)) return [];
  try {
    const bytes = Buffer.from(value.slice(VAULT_VERSION.length + 1), "base64url");
    if (bytes.length < 12 + 16) return [];
    const decipher = createDecipheriv("aes-256-gcm", vaultKey(secret), bytes.subarray(0, 12));
    decipher.setAuthTag(bytes.subarray(bytes.length - 16));
    const plain = Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]).toString("utf8");
    const rows: unknown = JSON.parse(plain);
    if (!Array.isArray(rows)) return [];
    const sessions: SavedSession[] = [];
    for (const row of rows) {
      if (!Array.isArray(row)) continue;
      const [id, refreshToken, savedAt] = row as unknown[];
      if (!isAccountId(id) || typeof refreshToken !== "string" || !refreshToken || typeof savedAt !== "number") continue;
      sessions.push({ id, refreshToken, savedAt });
    }
    return sessions.slice(0, ACCOUNT_HISTORY_LIMIT);
  } catch {
    return [];
  }
}

// MARK: The cookie

function cookieName(request: NextRequest): string {
  // The prefix makes browsers refuse the cookie from plain http.
  return request.nextUrl.protocol === "https:" ? `__Secure-${ACCOUNT_SESSIONS_COOKIE}` : ACCOUNT_SESSIONS_COOKIE;
}

export function readSessions(request: NextRequest, secret: string): SavedSession[] {
  return openSessions(request.cookies.get(cookieName(request))?.value, secret);
}

export function writeSessions(response: NextResponse, request: NextRequest, sessions: SavedSession[], secret: string): void {
  const empty = sessions.length === 0;
  response.cookies.set(cookieName(request), empty ? "" : sealSessions(sessions, secret), {
    httpOnly: true,
    maxAge: empty ? 0 : ACCOUNT_SESSIONS_MAX_AGE_SECONDS,
    path: ACCOUNT_SESSIONS_PATH,
    sameSite: "strict",
    secure: request.nextUrl.protocol === "https:",
  });
}
