import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../vms/routeHelpers";
import {
  parseNativeStackTokens,
  unauthorized,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
  type AuthedUser,
} from "../vms/auth";
import { resolveTeam } from "../subrouter/routeHelpers";
import {
  authenticateRequestRouteToken,
  VM_ID_HEADER,
  VM_AUTHORIZATION_HEADER,
  ROUTE_TOKEN_HEADER,
  routeTokenFromRequest,
} from "./routeTokenAuth";
import { accountAccessForIdentity, type CoderouterAccountAccess } from "./accountAccess";
import { recordCoderouterIdentity, spanned } from "./requestTelemetry";

export type CodeRouterRequestContext = {
  readonly user: AuthedUser;
  readonly team: {
    readonly teamId: string;
    readonly teamName: string;
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
};

/**
 * Control-plane authorization for account mutations.
 *
 * A Cloud VM is already authenticated by the TLS edge's VM-bound route token.
 * It must not be sent through Stack cookie/session resolution, and it must not
 * be able to choose another team. The token's team and VM pool are the entire
 * authority for the request. Human browser/native requests resolve team
 * membership through resolveCodeRouterRequestContext.
 */
export type CodeRouterControlContext = {
  readonly user: Pick<AuthedUser, "id">;
  readonly team: CodeRouterRequestContext["team"];
  readonly access: CoderouterAccountAccess;
};

export async function resolveCoderouterControlContext(
  request: Request,
): Promise<
  | { readonly ok: true; readonly value: CodeRouterControlContext }
  | { readonly ok: false; readonly response: Response }
> {
  const token = routeTokenFromRequest(request);
  if (request.headers.has(VM_AUTHORIZATION_HEADER) || token?.startsWith("crt_") || request.headers.has(VM_ID_HEADER) || request.headers.has(ROUTE_TOKEN_HEADER)) {
    const auth = await authenticateRequestRouteToken(request);
    if (!auth.ok) return { ok: false, response: jsonResponse({ error: auth.reason }, 401) };
    // A chatmux machine may use its team's shared accounts, never manage them.
    if (auth.identity.machine === "chatmux") {
      return { ok: false, response: jsonResponse({ error: "chatmux_machine_not_allowed" }, 403) };
    }
    if (!auth.identity.vmId) {
      return { ok: false, response: jsonResponse({ error: "vm_bound_token_required" }, 403) };
    }
    return {
      ok: true,
      value: {
        user: { id: auth.identity.stackUserId },
        team: {
          teamId: auth.identity.teamId,
          teamName: auth.identity.teamId,
          use: true,
          manageAccounts: true,
        },
        access: accountAccessForIdentity(auth.identity),
      },
    };
  }

  const resolved = await resolveCodeRouterRequestContext(request);
  if (!resolved.ok) return resolved;
  return {
    ok: true,
    value: {
      user: resolved.value.user,
      team: resolved.value.team,
      access: { kind: "user", userId: resolved.value.user.id },
    },
  };
}

export async function resolveCoderouterUsageTeam(
  request: Request,
): Promise<
  | { readonly ok: true; readonly teamId: string; readonly stackUserId: string; readonly access?: CoderouterAccountAccess; readonly vmId?: string | null }
  | { readonly ok: false; readonly response: Response }
> {
  const token = routeTokenFromRequest(request);
  if (request.headers.has(VM_AUTHORIZATION_HEADER) || token?.startsWith("crt_") || token?.startsWith("crk_") || request.headers.has(VM_ID_HEADER) || request.headers.has(ROUTE_TOKEN_HEADER)) {
    const auth = await authenticateRequestRouteToken(request);
    if (!auth.ok) return { ok: false, response: jsonResponse({ error: auth.reason }, 401) };
    const routed = auth.identity;
    return { ok: true, teamId: routed.teamId, stackUserId: routed.stackUserId,
      vmId: routed.vmId, access: accountAccessForIdentity(routed) };
  }
  const resolved = await resolveCodeRouterRequestContext(request);
  return resolved.ok
    ? {
      ok: true,
      teamId: resolved.value.team.teamId,
      stackUserId: resolved.value.user.id,
      access: { kind: "user", userId: resolved.value.user.id },
    }
    : resolved;
}

export async function resolveCodeRouterRequestContext(
  request: Request,
): Promise<
  | { readonly ok: true; readonly value: CodeRouterRequestContext }
  | { readonly ok: false; readonly response: Response }
> {
  // A guest's injected identity must never fall through to a browser session,
  // selected organization, or another credential it supplies alongside it.
  if (request.headers.has(VM_AUTHORIZATION_HEADER) || request.headers.has(VM_ID_HEADER)) {
    return { ok: false, response: jsonResponse({ error: "vm_management_forbidden" }, 403) };
  }
  return await spanned("auth", () => withSubrouterAuthorizationDeadline(async (signal) => {
    const requestedTeamId = requestedVmTeamIdFromRequest(request);
    const user = await verifySubrouterRequest(request, signal, {
      requestedTeamId,
      allowCookie: true,
    });
    if (!user) return { ok: false, response: unauthorized() };

    const bearer = parseBearer(request);
    if (
      requiresBrowserMutationProtection(request.method, bearer) &&
      !browserMutationOriginAllowed(request)
    ) {
      return { ok: false, response: jsonResponse({ error: "forbidden" }, 403) };
    }

    // Membership is the only requirement; resolveTeam already rejected
    // non-members with team_not_found.
    const team = resolveTeam(request, user);
    if (!team.ok) return team;

    // Browser-authenticated control-plane requests do not have a route token,
    // so record the resolved Stack identity and team together for the
    // PostHog trace.
    recordCoderouterIdentity({ teamId: team.teamId, stackUserId: user.id, vmId: null }, "control_plane");

    // Parse native tokens so malformed mixed auth never falls through as a
    // browser-cookie request. Verification above remains authoritative.
    parseNativeStackTokens(request);
    return { ok: true, value: { user, team } };
  }));
}
