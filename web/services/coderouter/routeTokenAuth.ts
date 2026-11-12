// Shared credential authentication for every coderouter data-plane surface
// (codex responses/models, opencode config/proxy, the Claude messages leg).
//
// VM credentials arrive only in x-cmux-authorization. Their verified claims
// supply identity; the repository checks revocation and current ownership.
// Unbound CLI sessions and user API keys keep their existing authentication.
import {
  authenticateApiKey,
  authenticateRouteToken,
  type RouteTokenPrincipal,
} from "./repository";
import {
  isKnownVmAuthorizationKey,
  unverifiedVmAuthorizationKeyId,
  VM_AUTHORIZATION_HEADER,
  type VmAuthorizationClaims,
  verifyVmAuthorization,
} from "./vmAuthorization";
import {
  recordCoderouterAuthFailure,
  recordCoderouterAuthStarted,
  recordCoderouterIdentity,
  recordCoderouterSignedVmClaims,
  recordCoderouterSpan,
} from "./requestTelemetry";
import { CHATMUX_VM_AUTHORIZATION_HEADER, verifyChatmuxVmToken } from "./chatmuxVmToken";

export const ROUTE_TOKEN_HEADER = "x-coderouter-route-token";
export const VM_ID_HEADER = "x-cmux-vm-id";
export { VM_AUTHORIZATION_HEADER };

/**
 * The public, non-secret value a VM-wired harness sends as its API key. It
 * satisfies "non-empty key" client checks; the real credential is the route
 * token the edge injects. Never matches the `crt_` token grammar, so it can
 * never be mistaken for a token by any verifier.
 */
import { VM_PLACEHOLDER_API_KEY } from "./vmGuestEnv";
export { VM_PLACEHOLDER_API_KEY };

export type RouteTokenIdentity = {
  readonly teamId: string;
  readonly stackUserId: string;
  /** The Cloud VM this token is bound to, or null for an unbound (CLI) token. */
  readonly vmId: string | null;
  readonly token: string;
  /** Opaque database id for a long-lived API key, or null for route tokens. */
  readonly apiKeyId?: string | null;
  readonly poolId?: string | null;
  /** A chatmux machine: team-shared accounts only (accountAccess.ts). */
  readonly machine?: "chatmux";
};

export type RouteTokenAuthFailure =
  | "missing_route_token"
  | "invalid_route_token"
  | "vm_mismatch";

/**
 * Why a credential was refused, finer than the response reason and never
 * sent to the caller. `placeholder_only`: only the public placeholder key
 * arrived, so the provider edge injected nothing. `signed_unknown_key`: the
 * injected token names a key this deployment does not hold (another
 * deployment signed it). `signed_unverified`: it failed signature or claims. `not_live`: the
 * credential parsed but no live row matched (revoked, unknown, or the machine
 * is no longer live). `binding`: the row belongs to another machine.
 */
export type RouteTokenAuthFailureDetail =
  | "no_credential"
  | "placeholder_only"
  | "signed_unverified"
  | "signed_unknown_key"
  | "not_live"
  | "binding"
  | "chatmux_unverified";

export type RouteTokenAuthResult =
  | { readonly ok: true; readonly identity: RouteTokenIdentity }
  | {
    readonly ok: false;
    readonly reason: RouteTokenAuthFailure;
    readonly detail?: RouteTokenAuthFailureDetail;
    /** The unverified key id of a refused signed token. Diagnostic only. */
    readonly keyId?: string;
  };

/**
 * The credential a data-plane request carries, in precedence order:
 * the edge-injected route-token header, `Authorization: Bearer`, then
 * `x-api-key` (Anthropic-style clients). A placeholder is never a credential.
 */
export function routeTokenFromRequest(request: Request): string | null {
  if (request.headers.has(VM_AUTHORIZATION_HEADER)) {
    return /^Bearer[ \t]+([^\s,]+)$/i.exec(request.headers.get(VM_AUTHORIZATION_HEADER)?.trim() ?? "")?.[1] ?? null;
  }
  const routed = request.headers.get(ROUTE_TOKEN_HEADER)?.trim();
  if (routed) return routed;
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const bearer = /^Bearer[ \t]+(.+)$/i.exec(authorization)?.[1]?.trim();
  if (bearer && bearer !== VM_PLACEHOLDER_API_KEY) return bearer;
  const apiKey = request.headers.get("x-api-key")?.trim();
  if (apiKey && apiKey !== VM_PLACEHOLDER_API_KEY) return apiKey;
  return null;
}

type Authenticate = (
  token: string,
) => Promise<{
  readonly teamId: string;
  readonly stackUserId: string;
  readonly vmId?: string | null;
  readonly apiKeyId?: string | null;
  readonly poolId?: string | null;
} | null>;

export async function authenticateRequestRouteToken(
  request: Request,
  authenticate: Authenticate = authenticateCoderouterCredential,
): Promise<RouteTokenAuthResult> {
  const startedAt = performance.now();
  recordCoderouterAuthStarted();
  const result = await authenticateUnobserved(request, authenticate);
  recordCoderouterSpan({
    name: "auth",
    startedAt,
    ...(result.ok ? {} : { error: result.reason }),
    attributes: {
      outcome: result.ok ? "accepted" : result.reason,
      ...(result.ok ? { auth_mode: result.identity.apiKeyId ? "api_key" : "route_token" } : {}),
    },
  });
  if (result.ok) recordCoderouterIdentity(result.identity);
  else recordCoderouterAuthFailure(result.reason, result.detail, result.keyId);
  return result;
}

/**
 * A chatmux VM token (chatmuxVmToken.ts). When its header is present it is
 * the only credential considered: no fallback to another header, no database
 * lookup, and a bad token fails closed.
 */
async function authenticateChatmuxMachine(request: Request): Promise<RouteTokenAuthResult> {
  const value = request.headers.get(CHATMUX_VM_AUTHORIZATION_HEADER)?.trim() ?? "";
  const token = /^Bearer[ \t]+([^\s,]+)$/i.exec(value)?.[1];
  const claims = token ? await verifyChatmuxVmToken(token) : null;
  if (!token || !claims) return { ok: false, reason: "invalid_route_token", detail: "chatmux_unverified" };
  return {
    ok: true,
    identity: {
      teamId: claims.team_id,
      stackUserId: claims.owner_id,
      vmId: `chatmux:${claims.sub.slice("vm:".length)}`,
      token,
      machine: "chatmux",
    },
  };
}

function signedRefusal(token: string): RouteTokenAuthResult {
  const keyId = unverifiedVmAuthorizationKeyId(token);
  const detail = keyId !== undefined && !isKnownVmAuthorizationKey(keyId) ? "signed_unknown_key" : "signed_unverified";
  return { ok: false, reason: "invalid_route_token", detail, ...(keyId ? { keyId } : {}) };
}

function carriesPlaceholder(request: Request): boolean {
  const bearer = /^Bearer[ \t]+(.+)$/i.exec(request.headers.get("authorization")?.trim() ?? "")?.[1]?.trim();
  return bearer === VM_PLACEHOLDER_API_KEY || request.headers.get("x-api-key")?.trim() === VM_PLACEHOLDER_API_KEY;
}

function isVmAuthorizationCandidate(token: string): boolean {
  return !token.startsWith("crt_") && !token.startsWith("crk_") &&
    token.length <= 4096 && /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token);
}

function vmAuthorizationClaims(token: string): Promise<VmAuthorizationClaims | null> {
  if (!isVmAuthorizationCandidate(token)) return Promise.resolve(null);
  return verifyVmAuthorization(token);
}

async function authenticateUnobserved(
  request: Request,
  authenticate: Authenticate,
): Promise<RouteTokenAuthResult> {
  if (request.headers.has(CHATMUX_VM_AUTHORIZATION_HEADER)) return await authenticateChatmuxMachine(request);
  const signedHeader = request.headers.has(VM_AUTHORIZATION_HEADER);
  const token = routeTokenFromRequest(request);
  if (!token) {
    if (signedHeader) return { ok: false, reason: "invalid_route_token", detail: "signed_unverified" };
    return { ok: false, reason: "missing_route_token", detail: carriesPlaceholder(request) ? "placeholder_only" : "no_credential" };
  }
  // A provider edge may preserve the standard bearer/route headers while
  // dropping the custom signed header. Verify the same JWT before falling
  // back to the legacy VM-id binding so those requests retain the signed
  // identity contract. Human route tokens and API keys keep their existing
  // prefix-based authentication paths.
  const signedToken = signedHeader || isVmAuthorizationCandidate(token);
  const claims = await vmAuthorizationClaims(token);
  if (signedToken && !claims) return signedRefusal(token);
  // The signature verified; attribute a crash in the ownership lookup below
  // to this machine and team instead of to nobody.
  if (claims) {
    recordCoderouterSignedVmClaims({ teamId: claims.team_id, vmId: claims.vm_id, stackUserId: claims.owner_id });
  }
  const identity = await authenticate(token);
  if (!identity) return { ok: false, reason: "invalid_route_token", detail: "not_live" };
  if (!validVmBinding(request, identity, claims)) return { ok: false, reason: "vm_mismatch", detail: "binding" };
  const legacyVmId = identity.vmId ?? null;
  const vmId = claims?.vm_id ?? legacyVmId;
  return {
    ok: true,
    identity: {
      teamId: claims?.team_id ?? identity.teamId,
      stackUserId: claims?.owner_id ?? identity.stackUserId,
      vmId,
      token,
      ...(identity.poolId ? { poolId: identity.poolId } : {}),
      ...(identity.apiKeyId ? { apiKeyId: identity.apiKeyId } : {}),
    },
  };
}

/** Authenticate either a short-lived route token or a user API key. */
export async function authenticateCoderouterCredential(
  token: string,
): Promise<RouteTokenPrincipal | null> {
  if (token.startsWith("crk_")) return await authenticateApiKey(token);
  return await authenticateRouteToken(token);
}

function matchesVmClaims(identity: Awaited<ReturnType<Authenticate>> & {}, claims: VmAuthorizationClaims): boolean {
  return identity.vmId === claims.vm_id && identity.teamId === claims.team_id && identity.stackUserId === claims.owner_id;
}

function validVmBinding(
  request: Request,
  identity: Awaited<ReturnType<Authenticate>> & {},
  claims: VmAuthorizationClaims | null,
): boolean {
  if (claims) return matchesVmClaims(identity, claims);
  const vmId = identity.vmId ?? null;
  if (vmId === null) return !request.headers.has(VM_ID_HEADER);
  return request.headers.get(VM_ID_HEADER)?.trim() === vmId;
}
