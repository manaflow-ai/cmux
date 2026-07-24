// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.
//
// Stack Auth verification for the share worker, trimmed from
// workers/presence/src/auth.ts (no team resolution: shares are scoped by
// unguessable share id + explicit host approval, not by team).
//
// Two call shapes share one verification path:
//   - `POST /v1/share/create` sends `Authorization: Bearer <access token>`
//   - the viewer WebSocket sends `?access_token=` (browsers cannot set WS
//     headers), extracted by the route and passed to `verifyAccessToken`.
//
// The worker calls Stack's REST `/api/v1/users/me` with the client access
// type, which both validates the access token server-side and yields the
// user's identity. Unlike presence, the share protocol shows each viewer's
// email and display name to the host (join requests) and to other
// participants (presence frames), so those fields ride along. Results are
// cached in isolate memory keyed by a SHA-256 of the token, bounded by the
// token's own `exp` and a short TTL so revocation latency stays small.

export interface AuthEnv {
  /** Stack REST API origin. Defaults to the hosted https://api.stack-auth.com. */
  STACK_API_URL?: string;
  STACK_PROJECT_ID?: string;
  STACK_PUBLISHABLE_CLIENT_KEY?: string;
}

export interface AuthedUser {
  id: string;
  primaryEmail: string;
  displayName: string;
}

/** Max cache age. A revoked-but-unexpired token stays usable for at most this
 * long, which is acceptable here: admission still requires explicit host
 * approval, and the host can end the session at any time. */
export const AUTH_CACHE_TTL_MS = 60_000;
const AUTH_CACHE_MAX_ENTRIES = 1024;
/** Negative cache window for a token Stack rejected. Bounds the amplification
 * where an unauthenticated caller forces one Stack subrequest per request by
 * sending an opaque (non-JWT, so no client-side expiry short-circuit) token. */
export const AUTH_NEGATIVE_CACHE_TTL_MS = 10_000;

interface CacheEntry {
  /** null marks a verified-failure (negative) entry. */
  user: AuthedUser | null;
  expiresAt: number;
}

// Isolate-global; resets whenever the isolate is recycled, which only costs an
// extra Stack round trip.
const authCache = new Map<string, CacheEntry>();

/** Cache deadline for a verified token: short TTL, never past the token's own
 * expiry. Pure for tests. */
export function cacheDeadline(
  nowMs: number,
  tokenExpMs: number | null,
  ttlMs: number = AUTH_CACHE_TTL_MS,
): number {
  const ttlDeadline = nowMs + ttlMs;
  if (tokenExpMs === null) return ttlDeadline;
  return Math.min(ttlDeadline, tokenExpMs);
}

/** Best-effort `exp` (epoch ms) from a JWT payload without verifying the
 * signature; verification is the Stack API call itself. Returns null for
 * opaque or malformed tokens. Pure for tests. */
export function tokenExpiryMs(token: string): number | null {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(base64)) as { exp?: unknown };
    return typeof payload.exp === "number" ? payload.exp * 1000 : null;
  } catch {
    return null;
  }
}

function normalized(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

/** The bearer access token from the Authorization header, or null. */
export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.toLowerCase().startsWith("bearer ")) return null;
  return normalized(header.slice("bearer ".length));
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function stackHeaders(env: AuthEnv, accessToken: string): Record<string, string> {
  return {
    "x-stack-access-type": "client",
    "x-stack-project-id": env.STACK_PROJECT_ID ?? "",
    "x-stack-publishable-client-key": env.STACK_PUBLISHABLE_CLIENT_KEY ?? "",
    "x-stack-access-token": accessToken,
  };
}

async function fetchStackUser(env: AuthEnv, accessToken: string): Promise<AuthedUser | null> {
  const apiUrl = (env.STACK_API_URL ?? "https://api.stack-auth.com").replace(/\/$/, "");
  const meResponse = await fetch(`${apiUrl}/api/v1/users/me`, {
    headers: stackHeaders(env, accessToken),
  });
  if (!meResponse.ok) return null;
  const me = (await meResponse.json()) as {
    id?: unknown;
    primary_email?: unknown;
    display_name?: unknown;
  };
  const userId = typeof me.id === "string" && me.id ? me.id : null;
  if (!userId) return null;
  const primaryEmail =
    typeof me.primary_email === "string" && me.primary_email ? me.primary_email : "";
  const displayName =
    typeof me.display_name === "string" && me.display_name ? me.display_name : "";
  return { id: userId, primaryEmail, displayName };
}

/** Verify an access token (from a bearer header or a `?access_token=` query
 * param). Returns the resolved user or null when unauthenticated or when
 * Stack auth is not configured (fail closed). */
export async function verifyAccessToken(
  token: string | null,
  env: AuthEnv,
): Promise<AuthedUser | null> {
  if (!env.STACK_PROJECT_ID || !env.STACK_PUBLISHABLE_CLIENT_KEY) return null;
  if (!token) return null;

  const now = Date.now();
  const expMs = tokenExpiryMs(token);
  if (expMs !== null && expMs <= now) return null;

  const cacheKey = await sha256Hex(token);
  const cached = authCache.get(cacheKey);
  // A live entry serves either a verified user or a verified failure (null),
  // so a rejected token does not re-hit Stack on every request.
  if (cached && cached.expiresAt > now) return cached.user;
  authCache.delete(cacheKey);

  const user = await fetchStackUser(env, token);

  if (authCache.size >= AUTH_CACHE_MAX_ENTRIES) {
    // Drop the oldest insertion; Map preserves insertion order.
    const oldest = authCache.keys().next().value;
    if (oldest !== undefined) authCache.delete(oldest);
  }
  if (!user) {
    // Negative cache: never past the token's own expiry.
    const negativeDeadline =
      expMs === null
        ? now + AUTH_NEGATIVE_CACHE_TTL_MS
        : Math.min(now + AUTH_NEGATIVE_CACHE_TTL_MS, expMs);
    authCache.set(cacheKey, { user: null, expiresAt: negativeDeadline });
    return null;
  }
  authCache.set(cacheKey, { user, expiresAt: cacheDeadline(now, expMs) });
  return user;
}

/** Verify the caller from the Authorization header. */
export async function verifyRequest(request: Request, env: AuthEnv): Promise<AuthedUser | null> {
  return verifyAccessToken(bearerToken(request), env);
}
