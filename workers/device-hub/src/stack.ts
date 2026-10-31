import { decodeJws, verifyEs256Jwk, verifyRs256Jwk } from "./crypto";
import { type Env, csv } from "./env";
import { badRequest, unauthorized } from "./errors";

/** Accepted Stack projects: STACK_PROJECT_IDS, else STACK_PROJECT_ID. */
export function allowedStackProjects(env: Pick<Env, "STACK_PROJECT_IDS" | "STACK_PROJECT_ID">): string[] {
  const list = csv(env.STACK_PROJECT_IDS);
  return list.length > 0 ? list : csv(env.STACK_PROJECT_ID);
}

export const STACK_API = "https://api.stack-auth.com";
const JWKS_TTL_MS = 10 * 60 * 1000;
const CLOCK_SKEW_S = 60;

type Jwk = JsonWebKey & { kid?: string };
const cache = new Map<string, { keys: Jwk[]; fetchedAt: number }>();

/** Test hook. */
export function resetStackJwksCache() {
  cache.clear();
}

export const stackIssuer = (api: string, projectId: string) => `${api}/api/v1/projects/${projectId}`;

async function loadKeys(api: string, projectId: string, now: number, force: boolean): Promise<Jwk[]> {
  const cacheKey = `${api}|${projectId}`;
  const hit = cache.get(cacheKey);
  if (!force && hit && now - hit.fetchedAt < JWKS_TTL_MS) return hit.keys;
  const res = await fetch(`${stackIssuer(api, projectId)}/.well-known/jwks.json`);
  if (!res.ok) throw new Error(`stack jwks ${res.status}`);
  const body = (await res.json()) as { keys?: Jwk[] };
  const keys = body.keys ?? [];
  cache.set(cacheKey, { keys, fetchedAt: now });
  return keys;
}

/**
 * Verifies a Stack Auth access token (same rules as the cmux-next mobile
 * Worker): ES256/RS256 against the project's JWKS, iss =
 * <api>/api/v1/projects/<projectId>, aud = projectId, not expired, not
 * anonymous. Stack tokens carry their project as `aud` (and in `iss`); the
 * project is taken from the unverified `aud`, must be one of `allowed`, and
 * the token is then verified against that project's own JWKS and issuer.
 */
export async function verifyStackAccessToken(token: string, allowed: string[], api: string, now: number): Promise<{ projectId: string; sub: string; exp: number }> {
  if (allowed.length === 0) throw badRequest("Stack Auth is not configured");
  let decoded;
  try {
    decoded = decodeJws(token);
  } catch {
    throw unauthorized("malformed access token");
  }
  const { header, payload, signingInput, signature } = decoded;
  const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  const listed = auds.filter((a): a is string => typeof a === "string" && allowed.includes(a));
  if (listed.length !== 1) throw unauthorized("access token is not for an accepted project");
  const projectId = listed[0]!;
  if ((header.alg !== "ES256" && header.alg !== "RS256") || typeof header.kid !== "string") throw unauthorized("unsupported access token");
  let jwk = (await loadKeys(api, projectId, now, false)).find((k) => k.kid === header.kid);
  if (!jwk) jwk = (await loadKeys(api, projectId, now, true)).find((k) => k.kid === header.kid);
  if (!jwk) throw unauthorized("unknown access token key");
  let ok = false;
  try {
    ok = header.alg === "ES256" ? await verifyEs256Jwk(jwk, signingInput, signature) : await verifyRs256Jwk(jwk, signingInput, signature);
  } catch {
    ok = false;
  }
  if (!ok) throw unauthorized("bad access token signature");
  if (payload.iss !== stackIssuer(api, projectId)) throw unauthorized("bad access token issuer");
  if (typeof payload.exp !== "number" || payload.exp + CLOCK_SKEW_S <= now / 1000) throw unauthorized("access token expired");
  if (typeof payload.sub !== "string" || !payload.sub) throw unauthorized("access token has no subject");
  if (payload.is_anonymous === true) throw unauthorized("anonymous Stack users cannot sign in");
  return { projectId, sub: payload.sub, exp: payload.exp };
}
