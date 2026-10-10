import { decodeJwt, verifyEs256, verifyRs256 } from "./crypto";
import { badRequest, unauthorized } from "./errors";

export const STACK_API = "https://api.stack-auth.com";
const JWKS_TTL_MS = 10 * 60 * 1000;
const CLOCK_SKEW_S = 60;

type Jwk = JsonWebKey & { kid?: string };
const cache = new Map<string, { keys: Jwk[]; fetchedAt: number }>();

/** Test hook. */
export function resetStackJwksCache() {
  cache.clear();
}

export const stackIssuer = (projectId: string) => `${STACK_API}/api/v1/projects/${projectId}`;

async function loadKeys(projectId: string, fetcher: typeof fetch, now: number, force: boolean): Promise<Jwk[]> {
  const hit = cache.get(projectId);
  if (!force && hit && now - hit.fetchedAt < JWKS_TTL_MS) return hit.keys;
  const res = await fetcher(`${stackIssuer(projectId)}/.well-known/jwks.json`);
  if (!res.ok) throw new Error(`stack jwks ${res.status}`);
  const body = (await res.json()) as { keys?: Jwk[] };
  const keys = body.keys ?? [];
  cache.set(projectId, { keys, fetchedAt: now });
  return keys;
}

export interface StackClaims {
  sub: string;
  email: string | null;
  emailVerified: boolean;
  name: string | null;
}

/**
 * Verifies a Stack Auth access token: ES256 against the project's JWKS,
 * iss = https://api.stack-auth.com/api/v1/projects/<projectId>, aud = projectId,
 * not expired, not anonymous.
 */
export async function verifyStackAccessToken(token: string, projectId: string, allowed: string[], fetcher: typeof fetch, now: number): Promise<StackClaims> {
  if (!allowed.includes(projectId)) throw badRequest("projectId is not allowed");
  let decoded;
  try {
    decoded = decodeJwt(token);
  } catch {
    throw unauthorized("malformed access token");
  }
  const { header, payload, signingInput, signature } = decoded;
  if ((header.alg !== "ES256" && header.alg !== "RS256") || typeof header.kid !== "string") throw unauthorized("unsupported access token");
  let jwk = (await loadKeys(projectId, fetcher, now, false)).find((k) => k.kid === header.kid);
  if (!jwk) jwk = (await loadKeys(projectId, fetcher, now, true)).find((k) => k.kid === header.kid);
  if (!jwk) throw unauthorized("unknown access token key");
  let ok = false;
  try {
    ok = header.alg === "ES256" ? await verifyEs256(jwk, signingInput, signature) : await verifyRs256({ kty: jwk.kty, n: jwk.n, e: jwk.e }, signingInput, signature);
  } catch {
    ok = false;
  }
  if (!ok) throw unauthorized("bad access token signature");
  if (payload.iss !== stackIssuer(projectId)) throw unauthorized("bad access token issuer");
  const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!aud.includes(projectId)) throw unauthorized("bad access token audience");
  const nowS = now / 1000;
  if (typeof payload.exp !== "number" || payload.exp + CLOCK_SKEW_S <= nowS) throw unauthorized("access token expired");
  if (typeof payload.sub !== "string" || !payload.sub) throw unauthorized("access token has no subject");
  if (payload.is_anonymous === true) throw unauthorized("anonymous Stack users cannot sign in");
  const email = typeof payload.email === "string" && payload.email ? payload.email : null;
  return {
    sub: payload.sub,
    email,
    emailVerified: email !== null && payload.email_verified === true,
    name: typeof payload.name === "string" && payload.name ? payload.name : null,
  };
}

/** Falls back to Stack's /users/me for the email and name when the token has none. */
export async function fetchStackUser(token: string, projectId: string, fetcher: typeof fetch): Promise<Partial<StackClaims>> {
  const res = await fetcher(`${STACK_API}/api/v1/users/me`, {
    headers: { "x-stack-access-token": token, "x-stack-project-id": projectId, "x-stack-access-type": "client" },
  });
  if (!res.ok) throw new Error(`stack users/me ${res.status}`);
  const u = (await res.json()) as { primary_email?: string | null; primary_email_verified?: boolean; display_name?: string | null };
  const email = u.primary_email || null;
  return { email, emailVerified: email !== null && u.primary_email_verified === true, name: u.display_name || null };
}
