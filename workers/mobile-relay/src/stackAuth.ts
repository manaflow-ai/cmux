// Stack access-token verification for the relay worker and Durable Object.
//
// The endpoint's token is verified against the Stack API with the CLIENT
// access type — the same check the Mac's own verifier performs — using only
// non-secret configuration (project id + publishable client key). A short
// per-isolate verdict cache keyed by token hash keeps reconnect bursts and
// in-band refreshes from re-hitting Stack; failures are never cached.

import { MAX_ACCESS_TOKEN_CHARS } from "./protocol";

export interface StackAuthEnv {
  STACK_PROJECT_ID?: string;
  STACK_PUBLISHABLE_CLIENT_KEY?: string;
  /** Defaults to the hosted Stack API. */
  STACK_API_URL?: string;
}

export type StackVerification =
  | { readonly ok: true; readonly userId: string }
  | { readonly ok: false; readonly error: "not_configured" | "invalid_token" | "verify_unavailable" };

const CACHE_TTL_MS = 60 * 1000;
const CACHE_MAX_ENTRIES = 256;
const VERIFY_TIMEOUT_MS = 10 * 1000;
const DEFAULT_STACK_API_URL = "https://api.stack-auth.com";

interface CacheEntry {
  readonly userId: string;
  readonly expiresAt: number;
}

// Per-isolate; both the worker and the object benefit within their isolates.
const verdictCache = new Map<string, CacheEntry>();

async function tokenCacheKey(accessToken: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(accessToken));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function readCache(key: string, nowMs: number): CacheEntry | null {
  const entry = verdictCache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= nowMs) {
    verdictCache.delete(key);
    return null;
  }
  return entry;
}

function writeCache(key: string, userId: string, nowMs: number): void {
  if (verdictCache.size >= CACHE_MAX_ENTRIES) {
    // Insertion-order eviction; entries are same-TTL so the oldest inserted
    // is also the closest to expiry.
    const oldest = verdictCache.keys().next().value;
    if (oldest !== undefined) verdictCache.delete(oldest);
  }
  verdictCache.set(key, { userId, expiresAt: nowMs + CACHE_TTL_MS });
}

/** Test seam. */
export function clearStackVerdictCacheForTesting(): void {
  verdictCache.clear();
}

export async function verifyStackAccessToken(
  env: StackAuthEnv,
  accessToken: string,
  nowMs: number,
  fetchImpl: typeof fetch = fetch,
): Promise<StackVerification> {
  const projectId = env.STACK_PROJECT_ID?.trim();
  const publishableClientKey = env.STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  if (!projectId || !publishableClientKey) return { ok: false, error: "not_configured" };
  const token = accessToken.trim();
  if (!token || token.length > MAX_ACCESS_TOKEN_CHARS) return { ok: false, error: "invalid_token" };

  const cacheKey = await tokenCacheKey(token);
  const cached = readCache(cacheKey, nowMs);
  if (cached) return { ok: true, userId: cached.userId };

  const base = (env.STACK_API_URL?.trim() || DEFAULT_STACK_API_URL).replace(/\/$/, "");
  let response: Response;
  try {
    response = await fetchImpl(`${base}/api/v1/users/me`, {
      headers: {
        "x-stack-access-type": "client",
        "x-stack-project-id": projectId,
        "x-stack-publishable-client-key": publishableClientKey,
        "x-stack-access-token": token,
      },
      signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS),
    });
  } catch {
    return { ok: false, error: "verify_unavailable" };
  }
  if (response.status === 401 || response.status === 400 || response.status === 403) {
    return { ok: false, error: "invalid_token" };
  }
  if (!response.ok) return { ok: false, error: "verify_unavailable" };
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return { ok: false, error: "verify_unavailable" };
  }
  const userId = (body as { id?: unknown }).id;
  if (typeof userId !== "string" || userId.length === 0) {
    return { ok: false, error: "verify_unavailable" };
  }
  writeCache(cacheKey, userId, nowMs);
  return { ok: true, userId };
}
