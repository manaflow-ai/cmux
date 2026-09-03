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
import { authenticateRouteToken } from "./repository";

export type CodeRouterRequestContext = {
  readonly user: AuthedUser;
  readonly team: {
    readonly teamId: string;
    readonly teamName: string;
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
};

export async function resolveCoderouterUsageTeam(
  request: Request,
): Promise<
  | { readonly ok: true; readonly teamId: string; readonly stackUserId: string }
  | { readonly ok: false; readonly response: Response }
> {
  const authorization = request.headers.get("authorization");
  const token = authorization?.match(/^Bearer\s+(\S+)$/i)?.[1];
  if (token?.startsWith("crt_")) {
    const routed = await authenticateRouteToken(token);
    if (routed) {
      return { ok: true, teamId: routed.teamId, stackUserId: routed.stackUserId };
    }
  }
  const resolved = await resolveCodeRouterRequestContext(request);
  return resolved.ok
    ? {
      ok: true,
      teamId: resolved.value.team.teamId,
      stackUserId: resolved.value.user.id,
    }
    : resolved;
}

export async function resolveCodeRouterRequestContext(
  request: Request,
): Promise<
  | { readonly ok: true; readonly value: CodeRouterRequestContext }
  | { readonly ok: false; readonly response: Response }
> {
  return await withSubrouterAuthorizationDeadline(async (signal) => {
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

    // Parse native tokens so malformed mixed auth never falls through as a
    // browser-cookie request. Verification above remains authoritative.
    parseNativeStackTokens(request);
    return { ok: true, value: { user, team } };
  });
}
