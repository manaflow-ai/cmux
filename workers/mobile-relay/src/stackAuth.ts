// Stack access-token verification for the relay worker and Durable Object.
//
// Access tokens are ES256 JWTs signed by the Stack backend; the primary path
// verifies them LOCALLY against the project's published JWKS
// (`/api/v1/projects/<id>/.well-known/jwks.json`), so a connect normally
// costs zero upstream round trips. The JWKS is cached per isolate with
// jose's remote set (kid-miss refetch handles key rotation). Tokens that are
// not structurally JWTs fall back to the legacy `/users/me` check with the
// CLIENT access type. A short per-isolate verdict cache keyed by token hash
// keeps reconnect bursts from re-verifying; failures are never cached.
//
// Claim contract (mirrors the backend's signer): `sub` is the user id and
// `aud` is the project id — an `:anon` or `:restricted` audience suffix
// marks a user class that must never reach a relay host, so only the exact
// project id is accepted. `iss` is pinned to the issuer the backend derives
// from its API base URL (`<base>/api/v1/projects/<projectId>`, verified
// against a real token 2026-08); the allow-set is computed from the
// configured STACK_API_URL, plus its stack-auth ↔ hexclave rebrand alias
// host (the backend's validator accepts both during the domain transition).

import { createLocalJWKSet, decodeProtectedHeader, jwtVerify } from "jose";
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
  jwksByUrl.clear();
}

// The JWKS is fetched as plain JSON with the injected fetch (testable) and
// cached per isolate: 24h TTL, with a cooldown-limited refetch when a token
// names an unknown kid (key rotation).
interface JwksEntry {
  set: ReturnType<typeof createLocalJWKSet>;
  kids: Set<string>;
  fetchedAtMs: number;
}
const jwksByUrl = new Map<string, JwksEntry>();
const JWKS_TTL_MS = 24 * 60 * 60 * 1000;
const JWKS_KID_MISS_COOLDOWN_MS = 60 * 1000;

async function loadJwks(
  url: string,
  fetchImpl: typeof fetch,
  nowMs: number,
): Promise<JwksEntry | null> {
  let response: Response;
  try {
    response = await fetchImpl(url, { signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS) });
  } catch {
    return null;
  }
  if (!response.ok) return null;
  let body: { keys?: { kid?: string }[] };
  try {
    body = (await response.json()) as { keys?: { kid?: string }[] };
  } catch {
    return null;
  }
  if (!Array.isArray(body.keys)) return null;
  try {
    const entry: JwksEntry = {
      set: createLocalJWKSet(body as Parameters<typeof createLocalJWKSet>[0]),
      kids: new Set(body.keys.map((key) => key.kid).filter((kid): kid is string => typeof kid === "string")),
      fetchedAtMs: nowMs,
    };
    jwksByUrl.set(url, entry);
    return entry;
  } catch {
    return null;
  }
}

// The stack-auth ↔ hexclave rebrand host pairs, mirroring the backend's
// `CLOUD_HOST_PAIRS` (`packages/shared/src/utils/cloud-hosts.tsx` in the
// Stack source): tokens minted under one brand host must validate under the
// other. A Map (not a plain object) avoids prototype-key collisions on a
// host string that ultimately comes from configuration.
const issuerHostAliases = new Map<string, string>(
  (
    [
      ["api.stack-auth.com", "api.hexclave.com"],
      ["api.dev.stack-auth.com", "api.dev.hexclave.com"],
      ["api.staging.stack-auth.com", "api.staging.hexclave.com"],
    ] as const
  ).flatMap(([stackAuthHost, hexclaveHost]) => [
    [stackAuthHost, hexclaveHost] as const,
    [hexclaveHost, stackAuthHost] as const,
  ]),
);

/**
 * Issuers a token for `projectId` may carry, derived from the configured
 * Stack API base URL exactly the way the backend's `getIssuer` builds the
 * claim for normal users: `new URL('/api/v1/projects/<id>', base)`. Anonymous
 * and restricted user types issue under `/projects-anonymous-users/` and
 * `/projects-restricted-users/`; those users are already rejected by the
 * audience check, so only the normal-user issuer is allowed.
 */
export function computeAllowedIssuers(base: string, projectId: string): string[] {
  let issuerUrl: URL;
  try {
    issuerUrl = new URL(`/api/v1/projects/${projectId}`, base);
  } catch {
    return [`${base.replace(/\/$/, "")}/api/v1/projects/${projectId}`];
  }
  const issuers = [issuerUrl.toString()];
  const aliasHost = issuerHostAliases.get(issuerUrl.host);
  if (aliasHost) {
    const aliased = new URL(issuerUrl.toString());
    aliased.host = aliasHost;
    issuers.push(aliased.toString());
  }
  return issuers;
}

function looksLikeJwt(token: string): boolean {
  return token.startsWith("ey") && token.split(".").length === 3;
}

async function verifyJwtLocally(
  token: string,
  projectId: string,
  base: string,
  fetchImpl: typeof fetch,
  nowMs: number,
): Promise<StackVerification | null> {
  let kid: string | undefined;
  try {
    kid = decodeProtectedHeader(token).kid;
  } catch {
    return null; // Not a JWT after all; the caller falls back.
  }
  const url = `${base}/api/v1/projects/${projectId}/.well-known/jwks.json`;
  let entry = jwksByUrl.get(url);
  if (!entry || nowMs - entry.fetchedAtMs > JWKS_TTL_MS) {
    entry = (await loadJwks(url, fetchImpl, nowMs)) ?? entry;
  } else if (kid !== undefined && !entry.kids.has(kid)
    && nowMs - entry.fetchedAtMs > JWKS_KID_MISS_COOLDOWN_MS) {
    // Unknown kid on a fresh-enough set: likely key rotation; refetch once
    // per cooldown window so a garbage kid cannot hammer the endpoint.
    entry = (await loadJwks(url, fetchImpl, nowMs)) ?? entry;
  }
  if (!entry) return { ok: false, error: "verify_unavailable" };
  try {
    const { payload } = await jwtVerify(token, entry.set, {
      algorithms: ["ES256"],
      // Exact project id only: `<id>:anon` / `<id>:restricted` audiences are
      // user classes a relay host must reject.
      audience: projectId,
      // Issuer pinned to the configured Stack API base (plus its rebrand
      // alias host); a mismatch is a definitive invalid_token.
      issuer: computeAllowedIssuers(base, projectId),
    });
    const userId = payload.sub;
    if (typeof userId !== "string" || userId.length === 0) {
      return { ok: false, error: "invalid_token" };
    }
    return { ok: true, userId };
  } catch {
    // With a fresh key set in hand, a verification failure is definitive.
    return { ok: false, error: "invalid_token" };
  }
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
  if (looksLikeJwt(token)) {
    const local = await verifyJwtLocally(token, projectId, base, fetchImpl, nowMs);
    if (local) {
      if (local.ok) writeCache(cacheKey, local.userId, nowMs);
      return local;
    }
  }
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
