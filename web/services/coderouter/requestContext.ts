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

export type CodeRouterRequestContext = {
  readonly user: AuthedUser;
  readonly team: {
    readonly teamId: string;
    readonly teamName: string;
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
};

export async function resolveCodeRouterRequestContext(
  request: Request,
  permission: "use" | "manage" | "use-or-manage" = "use",
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

    const team = await resolveTeam(request, user);
    if (!team.ok) return team;
    const permitted = permission === "manage"
      ? team.manageAccounts
      : permission === "use-or-manage"
      ? team.use || team.manageAccounts
      : team.use;
    if (!permitted) {
      return { ok: false, response: jsonResponse({ error: "forbidden" }, 403) };
    }

    // Parse native tokens so malformed mixed auth never falls through as a
    // browser-cookie request. Verification above remains authoritative.
    parseNativeStackTokens(request);
    return { ok: true, value: { user, team } };
  });
}
