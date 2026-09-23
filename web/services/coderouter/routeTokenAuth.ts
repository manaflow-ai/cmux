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
  VM_AUTHORIZATION_HEADER,
  type VmAuthorizationClaims,
  verifyVmAuthorization,
} from "./vmAuthorization";
import { recordCoderouterIdentity, recordCoderouterSpan } from "./requestTelemetry";

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
};

export type RouteTokenAuthFailure =
  | "missing_route_token"
  | "invalid_route_token"
  | "vm_mismatch";

export type RouteTokenAuthResult =
  | { readonly ok: true; readonly identity: RouteTokenIdentity }
  | { readonly ok: false; readonly reason: RouteTokenAuthFailure };

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
  return result;
}

async function authenticateUnobserved(
  request: Request,
  authenticate: Authenticate,
): Promise<RouteTokenAuthResult> {
  const signedHeader = request.headers.has(VM_AUTHORIZATION_HEADER);
  const token = routeTokenFromRequest(request);
  if (!token) return { ok: false, reason: signedHeader ? "invalid_route_token" : "missing_route_token" };
  const claims = signedHeader ? await verifyVmAuthorization(token) : null;
  if (signedHeader && !claims) return { ok: false, reason: "invalid_route_token" };
  const identity = await authenticate(token);
  if (!identity) return { ok: false, reason: "invalid_route_token" };
  if (!validVmBinding(request, identity, claims)) return { ok: false, reason: "vm_mismatch" };
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
