export type ShareAuthEnv = {
  readonly STACK_API_URL?: string;
  readonly STACK_PROJECT_ID?: string;
  readonly STACK_PUBLISHABLE_CLIENT_KEY?: string;
};

export type ShareAuthedUser = {
  readonly id: string;
  readonly email: string;
  readonly displayName: string;
};

const UNSAFE_DISPLAY_CHARACTERS = /[\u0000-\u001F\u007F-\u009F\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/gu;

const AUTH_CACHE_TTL_MS = 30_000;
const AUTH_CACHE_MAX_ENTRIES = 512;

type CacheEntry = {
  readonly user: ShareAuthedUser | null;
  readonly expiresAt: number;
};

const cache = new Map<string, CacheEntry>();

export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.toLowerCase().startsWith("bearer ")) return null;
  const token = header.slice("bearer ".length).trim();
  return token || null;
}

export async function verifyHostRequest(
  request: Request,
  env: ShareAuthEnv,
): Promise<ShareAuthedUser | null> {
  if (!env.STACK_PROJECT_ID || !env.STACK_PUBLISHABLE_CLIENT_KEY) return null;
  const token = bearerToken(request);
  if (!token) return null;
  const now = Date.now();
  const tokenExpiry = tokenExpiryMs(token);
  if (tokenExpiry !== null && tokenExpiry <= now) return null;
  const key = await sha256Hex(token);
  const cached = cache.get(key);
  if (cached && cached.expiresAt > now) return cached.user;
  cache.delete(key);

  const user = await fetchStackUser(env, token);
  if (cache.size >= AUTH_CACHE_MAX_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, {
    user,
    expiresAt: Math.min(now + (user ? AUTH_CACHE_TTL_MS : 5_000), tokenExpiry ?? Number.MAX_SAFE_INTEGER),
  });
  return user;
}

export async function capabilityHash(value: string): Promise<string> {
  return sha256Hex(value);
}

async function fetchStackUser(env: ShareAuthEnv, accessToken: string): Promise<ShareAuthedUser | null> {
  const base = (env.STACK_API_URL ?? "https://api.stack-auth.com").replace(/\/$/u, "");
  const response = await fetch(`${base}/api/v1/users/me`, {
    headers: {
      "x-stack-access-type": "client",
      "x-stack-project-id": env.STACK_PROJECT_ID ?? "",
      "x-stack-publishable-client-key": env.STACK_PUBLISHABLE_CLIENT_KEY ?? "",
      "x-stack-access-token": accessToken,
    },
  });
  if (!response.ok) return null;
  const body = await response.json() as Record<string, unknown>;
  return shareUserFromStackPayload(body);
}

export function shareUserFromStackPayload(body: Record<string, unknown>): ShareAuthedUser | null {
  if (body.is_anonymous === true || body.isAnonymous === true ||
      body.is_restricted === true || body.isRestricted === true) return null;
  const id = normalized(body.id, 256);
  const email = normalized(body.primary_email, 320) ?? normalized(body.primaryEmail, 320);
  const emailVerified = body.primary_email_verified === true || body.primaryEmailVerified === true;
  const displayName = safeDisplayName(body.display_name) ?? safeDisplayName(body.displayName) ?? email;
  return id && email && emailVerified && displayName ? { id, email, displayName } : null;
}

function safeDisplayName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return normalized(value.replace(UNSAFE_DISPLAY_CHARACTERS, " ").replace(/\s+/gu, " "), 256);
}

function normalized(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result && result.length <= max ? result : null;
}

function tokenExpiryMs(token: string): number | null {
  const payload = token.split(".")[1];
  if (!payload) return null;
  try {
    const padding = "=".repeat((4 - payload.length % 4) % 4);
    const parsed = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/") + padding)) as { exp?: unknown };
    return typeof parsed.exp === "number" ? parsed.exp * 1_000 : null;
  } catch {
    return null;
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
