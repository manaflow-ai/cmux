// Shared route-token authentication for every coderouter data-plane surface
// (codex responses/models, opencode config/proxy, the Claude messages leg).
//
// A route token may be bound to one Cloud VM (`coderouter_route_tokens.vm_id`).
// Such a token is only ever delivered by the Freestyle edge, which injects
// both `x-coderouter-route-token` and `x-cmux-vm-id` into the guest's session
// (the guest itself never holds the token). The database binding is the
// authority: a bound token whose request carries a different or missing
// `x-cmux-vm-id` is rejected, so a rule that was mis-provisioned for another
// machine, or a guest that forges the header, cannot spend a token that is
// not its own. Unbound tokens (the `cr` CLI) ignore the header.
import { authenticateRouteToken } from "./repository";

export const ROUTE_TOKEN_HEADER = "x-coderouter-route-token";
export const VM_ID_HEADER = "x-cmux-vm-id";

/**
 * The public, non-secret value a VM-wired harness sends as its API key. It
 * satisfies "non-empty key" client checks; the real credential is the route
 * token the edge injects. Never matches the `crt_` token grammar, so it can
 * never be mistaken for a token by any verifier.
 */
export const VM_PLACEHOLDER_API_KEY = "cmux-vm-edge-placeholder";

export type RouteTokenIdentity = {
  readonly teamId: string;
  readonly stackUserId: string;
  /** The Cloud VM this token is bound to, or null for an unbound (CLI) token. */
  readonly vmId: string | null;
  readonly token: string;
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
) => Promise<{ teamId: string; stackUserId: string; vmId?: string | null } | null>;

export async function authenticateRequestRouteToken(
  request: Request,
  authenticate: Authenticate = authenticateRouteToken,
): Promise<RouteTokenAuthResult> {
  const token = routeTokenFromRequest(request);
  if (!token) return { ok: false, reason: "missing_route_token" };
  const identity = await authenticate(token);
  if (!identity) return { ok: false, reason: "invalid_route_token" };
  const vmId = identity.vmId ?? null;
  if (vmId !== null) {
    const claimed = request.headers.get(VM_ID_HEADER)?.trim() ?? "";
    if (claimed !== vmId) return { ok: false, reason: "vm_mismatch" };
  }
  return {
    ok: true,
    identity: { teamId: identity.teamId, stackUserId: identity.stackUserId, vmId, token },
  };
}
