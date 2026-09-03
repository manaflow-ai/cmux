import {
  createRemoteJWKSet,
  errors as joseErrors,
  jwtVerify,
  type JWTPayload,
  type JWTVerifyGetKey,
} from "jose";

import { env } from "../../app/env";
import { stackApiBaseURL } from "./stackApiBaseURL";

/**
 * Identity proven by a Stack Auth access token whose signature we checked
 * ourselves against Stack's published keys. No Stack API call is involved.
 */
export type StackAccessTokenIdentity = {
  readonly userId: string;
  readonly projectId: string;
  readonly refreshTokenId: string | null;
  readonly isAnonymous: boolean;
  readonly expiresAt: Date;
};

export type StackAccessTokenVerifier = {
  readonly projectId: string;
  /** Stack API origin, e.g. https://api.stack-auth.com, no trailing slash. */
  readonly apiBaseURL: string;
  /** Test seam: replaces the remote JWKS resolver. */
  readonly getKey?: JWTVerifyGetKey;
  /** Test seam: replaces the wall clock used for exp/iat checks. */
  readonly now?: () => Date;
};

// Stack signs access tokens with ES256 and rotates the signing key under a
// new `kid`. Anything else (HS256, none, RS*) is rejected before key lookup.
const STACK_ACCESS_TOKEN_ALGORITHMS = ["ES256"];
// Vercel functions and Stack's signers both keep good time; one minute covers
// the observed skew without accepting meaningfully expired tokens.
const CLOCK_TOLERANCE_SECONDS = 60;
// Per-instance JWKS cache. Keys rotate rarely; an unknown `kid` triggers one
// refresh, and the cooldown stops a flood of forged tokens from turning into a
// flood of JWKS fetches from every instance.
const JWKS_CACHE_MAX_AGE_MS = 10 * 60 * 1_000;
const JWKS_REFRESH_COOLDOWN_MS = 30 * 1_000;
const JWKS_FETCH_TIMEOUT_MS = 3_000;
const KEY_SET_FAILURE_LOG_INTERVAL_MS = 60 * 1_000;

/**
 * Verifier configuration from the environment, or null when Stack is not
 * configured. Lives here (not in app/lib/stack) so tests that mock the Stack
 * SDK module keep working and so the JWKS origin follows the SDK's API origin.
 */
export function stackAccessTokenVerifierFromEnv(): StackAccessTokenVerifier | null {
  const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
  if (!projectId) return null;
  let apiBaseURL: string;
  try {
    apiBaseURL = stackApiBaseURL().replace(/\/api\/v1$/u, "");
  } catch {
    return null;
  }
  return { projectId, apiBaseURL };
}

export function stackIssuer(apiBaseURL: string, projectId: string): string {
  return `${apiBaseURL.replace(/\/+$/u, "")}/api/v1/projects/${projectId}`;
}

export function stackJwksURL(apiBaseURL: string, projectId: string): URL {
  return new URL(`${stackIssuer(apiBaseURL, projectId)}/.well-known/jwks.json`);
}

const remoteKeySets = new Map<string, JWTVerifyGetKey>();

function remoteKeySet(url: URL): JWTVerifyGetKey {
  const cached = remoteKeySets.get(url.href);
  if (cached) return cached;
  const created = createRemoteJWKSet(url, {
    cacheMaxAge: JWKS_CACHE_MAX_AGE_MS,
    cooldownDuration: JWKS_REFRESH_COOLDOWN_MS,
    timeoutDuration: JWKS_FETCH_TIMEOUT_MS,
  });
  remoteKeySets.set(url.href, created);
  return created;
}

/** Test hook: drop cached remote key sets. */
export function clearStackAccessTokenKeySetsForTests(): void {
  remoteKeySets.clear();
}

let lastKeySetFailureLogAt = 0;

/**
 * Verify a Stack access token locally.
 *
 * Returns the identity when the token is a well-formed ES256 JWT, signed by a
 * key in Stack's JWKS for this project, issued by this project, addressed to
 * this project, and not expired. Returns null for every other outcome,
 * including JWKS fetch failures, so the caller falls back to Stack's API and
 * behavior degrades to today's path instead of failing closed on our side.
 *
 * Revocation is not visible here: a session revoked at Stack keeps a valid
 * signature until `exp`. Stack access tokens live one hour.
 */
export async function verifyStackAccessTokenLocally(
  accessToken: string,
  verifier: StackAccessTokenVerifier,
): Promise<StackAccessTokenIdentity | null> {
  if (!looksLikeCompactJws(accessToken)) return null;
  const getKey = verifier.getKey
    ?? remoteKeySet(stackJwksURL(verifier.apiBaseURL, verifier.projectId));
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(accessToken, getKey, {
      algorithms: STACK_ACCESS_TOKEN_ALGORITHMS,
      issuer: stackIssuer(verifier.apiBaseURL, verifier.projectId),
      audience: verifier.projectId,
      clockTolerance: CLOCK_TOLERANCE_SECONDS,
      ...(verifier.now ? { currentDate: verifier.now() } : {}),
    }));
  } catch (error) {
    if (!isTokenRejection(error)) logKeySetFailure(error);
    return null;
  }
  if (typeof payload.sub !== "string" || payload.sub.length === 0) return null;
  if (
    payload.project_id !== undefined
    && payload.project_id !== verifier.projectId
  ) {
    return null;
  }
  if (typeof payload.exp !== "number") return null;
  return {
    userId: payload.sub,
    projectId: verifier.projectId,
    refreshTokenId: typeof payload.refresh_token_id === "string"
      ? payload.refresh_token_id
      : null,
    isAnonymous: payload.is_anonymous === true,
    expiresAt: new Date(payload.exp * 1_000),
  };
}

function looksLikeCompactJws(value: string): boolean {
  if (value.length < 20 || value.length > 8_192) return false;
  const parts = value.split(".");
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

/** A rejection of this token, as opposed to a failure to obtain Stack's keys. */
function isTokenRejection(error: unknown): boolean {
  return error instanceof joseErrors.JWTExpired
    || error instanceof joseErrors.JWTClaimValidationFailed
    || error instanceof joseErrors.JWTInvalid
    || error instanceof joseErrors.JWSInvalid
    || error instanceof joseErrors.JWSSignatureVerificationFailed
    || error instanceof joseErrors.JOSEAlgNotAllowed
    || error instanceof joseErrors.JOSENotSupported
    || error instanceof joseErrors.JWKSNoMatchingKey
    || error instanceof joseErrors.JWKSMultipleMatchingKeys;
}

function logKeySetFailure(error: unknown): void {
  const now = Date.now();
  if (now - lastKeySetFailureLogAt < KEY_SET_FAILURE_LOG_INTERVAL_MS) return;
  lastKeySetFailureLogAt = now;
  console.warn("stack access token key set unavailable; falling back to Stack API", {
    reason: error instanceof Error ? error.name : "unknown",
  });
}
