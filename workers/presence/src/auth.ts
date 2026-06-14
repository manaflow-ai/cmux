// Stack Auth verification for the presence worker.
//
// Mirrors `web/services/vms/auth.ts` (`verifyRequest` + `resolveTeam`): native
// clients send `Authorization: Bearer <access token>`, and the team scope comes
// from `X-Cmux-Team-Id` / `?teamId=` with a membership check, defaulting to the
// caller's selected team and then to the solo-account user id. The web app
// verifies through the Stack Next.js SDK; that SDK is just a wrapper over
// Stack's REST API, so here we call the same two endpoints directly
// (`/api/v1/users/me` and `/api/v1/teams?user_id=me`) with the client access
// type, which both validates the access token server-side and yields the team
// list. No cookie fallback: like the device-registry routes, only native
// header auth is accepted (`allowCookie: false` on the web side).
//
// Heartbeats arrive every 15s per host, so verification results are cached in
// isolate memory keyed by a SHA-256 of the access token, bounded by the
// token's own `exp` and a short TTL so revocation latency stays small.

export interface AuthEnv {
  /** Stack REST API origin. Defaults to the hosted https://api.stack-auth.com. */
  STACK_API_URL?: string;
  STACK_PROJECT_ID?: string;
  STACK_PUBLISHABLE_CLIENT_KEY?: string;
}

export interface AuthedUser {
  id: string;
  selectedTeamId: string | null;
  teamIds: readonly string[];
}

/** Max cache age. A revoked-but-unexpired token stays usable for at most this
 * long, which is acceptable for presence (read/announce, no mutations of
 * durable state). */
export const AUTH_CACHE_TTL_MS = 60_000;
const AUTH_CACHE_MAX_ENTRIES = 1024;
/** Negative cache window for a token Stack rejected. Bounds the amplification
 * where an unauthenticated caller forces one Stack subrequest per request by
 * sending an opaque (non-JWT, so no client-side expiry short-circuit) token;
 * short enough that a token which legitimately becomes valid is not stranded
 * for long. */
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

export type TeamResolution =
  | { ok: true; teamId: string }
  | { ok: false; error: "team_not_found" };

/** Resolve the team this request operates on, mirroring the web route exactly:
 * a requested team must be one the caller belongs to (their own user id counts
 * as the solo-account team); otherwise default to the selected team, then a
 * sole listed team, then the user id. Pure for tests. */
export function resolveTeamId(
  requested: string | null,
  user: AuthedUser,
): TeamResolution {
  if (requested) {
    const isMember = user.teamIds.includes(requested) || requested === user.id;
    if (!isMember) return { ok: false, error: "team_not_found" };
    return { ok: true, teamId: requested };
  }
  const soleTeam = user.teamIds.length === 1 ? user.teamIds[0] : null;
  return { ok: true, teamId: user.selectedTeamId ?? soleTeam ?? user.id };
}

/** Requested team from `X-Cmux-Team-Id` (or legacy billing header) or the
 * `teamId`-family query params, copied from
 * `web/services/vms/routeHelpers.ts#requestedVmTeamIdFromRequest`. */
export function requestedTeamIdFromRequest(request: Request): string | null {
  const fromHeader =
    normalized(request.headers.get("x-cmux-team-id")) ??
    normalized(request.headers.get("x-cmux-billing-team-id"));
  if (fromHeader) return fromHeader;
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return null;
  }
  return (
    normalized(url.searchParams.get("teamId")) ??
    normalized(url.searchParams.get("team_id")) ??
    normalized(url.searchParams.get("billingTeamId")) ??
    normalized(url.searchParams.get("billing_team_id"))
  );
}

function normalized(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

/** The bearer access token from the Authorization header, or null. Exported
 * so the subscribe route can bound stream lifetime to the token's expiry. */
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
  const headers = stackHeaders(env, accessToken);

  const meResponse = await fetch(`${apiUrl}/api/v1/users/me`, { headers });
  if (!meResponse.ok) return null;
  const me = (await meResponse.json()) as {
    id?: unknown;
    selected_team_id?: unknown;
    selected_team?: { id?: unknown } | null;
  };
  const userId = typeof me.id === "string" && me.id ? me.id : null;
  if (!userId) return null;
  const selectedTeamId =
    typeof me.selected_team_id === "string" && me.selected_team_id
      ? me.selected_team_id
      : typeof me.selected_team?.id === "string" && me.selected_team.id
        ? me.selected_team.id
        : null;

  // Membership list, equivalent to the web side's `user.listTeams()`. A
  // failure here fails closed (no cross-team access on a partial view).
  const teamsResponse = await fetch(`${apiUrl}/api/v1/teams?user_id=me`, { headers });
  if (!teamsResponse.ok) return null;
  const teams = (await teamsResponse.json()) as { items?: unknown };
  const teamIds = Array.isArray(teams.items)
    ? [
        ...new Set(
          teams.items
            .map((item) => (item as { id?: unknown }).id)
            .filter((id): id is string => typeof id === "string" && id.length > 0),
        ),
      ]
    : [];

  return { id: userId, selectedTeamId, teamIds };
}

/** Verify the caller. Returns the resolved user or null when unauthenticated
 * or when Stack auth is not configured (fail closed, like
 * `isStackConfigured()` on the web side). */
export async function verifyRequest(request: Request, env: AuthEnv): Promise<AuthedUser | null> {
  if (!env.STACK_PROJECT_ID || !env.STACK_PUBLISHABLE_CLIENT_KEY) return null;
  const token = bearerToken(request);
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
    // Negative cache: never past the token's own expiry (an expired-token
    // hash should fall through to the cheap expiry short-circuit next time).
    const negativeDeadline =
      expMs === null ? now + AUTH_NEGATIVE_CACHE_TTL_MS
        : Math.min(now + AUTH_NEGATIVE_CACHE_TTL_MS, expMs);
    authCache.set(cacheKey, { user: null, expiresAt: negativeDeadline });
    return null;
  }
  authCache.set(cacheKey, { user, expiresAt: cacheDeadline(now, expMs) });
  return user;
}
