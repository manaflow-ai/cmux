import {
  authenticateRequestRouteToken,
  ROUTE_TOKEN_HEADER,
  VM_AUTHORIZATION_HEADER,
  VM_ID_HEADER,
} from "../../../../services/coderouter/routeTokenAuth";
import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requiresBrowserMutationProtection,
} from "../../../../services/vms/routeHelpers";
import {
  isSubrouterAuthorizationError,
  unauthorized as unauthorizedResponse,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
  type AuthedUser,
} from "../../../../services/vms/auth";
import {
  authorizedSubrouterTeams,
  serviceUnavailableResponse,
} from "../../../../services/subrouter/routeHelpers";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import { getStackServerApp } from "../../../lib/stack";


export async function GET(request: Request): Promise<Response> {
  return organizationsGet(request, authorizedSubrouterTeams);
}

/** Create a Stack Auth team for the authenticated user and return its summary. */
export async function POST(request: Request): Promise<Response> {
  if (
    requiresBrowserMutationProtection(request.method, parseBearer(request)) &&
    !browserMutationOriginAllowed(request)
  ) return jsonResponse({ error: "forbidden" }, 403);
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return unauthorizedResponse();

      const payload = await request.json().catch(() => null) as { displayName?: unknown } | null;
      const displayName = typeof payload?.displayName === "string"
        ? payload.displayName.trim()
        : "";
      if (!displayName || displayName.length > 120) {
        return jsonResponse({ error: "invalid_team_name" }, 400);
      }

      const team = await getStackServerApp().createTeam({
        displayName,
        creatorUserId: user.id,
      });
      const stackUser = await getStackServerApp().getUser(user.id);
      if (!stackUser) return unauthorizedResponse();
      await stackUser.update({ selectedTeamId: team.id });
      return jsonResponse({
        team: { id: team.id, name: team.displayName },
        selectedTeamId: team.id,
      }, 201);
    });
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Subrouter team creation authorization unavailable", {
        errorType: error.name,
      });
      return serviceUnavailableResponse();
    }
    throw error;
  }
}

/** Persist the selected member team in Stack Auth for browser clients. */
export async function PATCH(request: Request): Promise<Response> {
  if (
    requiresBrowserMutationProtection(request.method, parseBearer(request)) &&
    !browserMutationOriginAllowed(request)
  ) return jsonResponse({ error: "forbidden" }, 403);
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return unauthorizedResponse();

      const payload = await request.json().catch(() => null) as { teamId?: unknown } | null;
      const teamId = typeof payload?.teamId === "string"
        ? payload.teamId.trim()
        : "";
      if (!teamId || (!user.teamIds.includes(teamId) && teamId !== user.id)) {
        return jsonResponse({ error: "team_not_found" }, 403);
      }

      const stackUser = await getStackServerApp().getUser(user.id);
      if (!stackUser) return unauthorizedResponse();
      await stackUser.update({ selectedTeamId: teamId });
      return jsonResponse({ selectedTeamId: teamId });
    });
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Subrouter team selection authorization unavailable", {
        errorType: error.name,
      });
      return serviceUnavailableResponse();
    }
    throw error;
  }
}

export async function organizationsGet(request: Request,
  listTeams: (user: AuthedUser) => ReturnType<typeof authorizedSubrouterTeams> | Promise<ReturnType<typeof authorizedSubrouterTeams>>,
  authenticate: typeof authenticateRequestRouteToken = authenticateRequestRouteToken,
): Promise<Response> {
  if (
    request.headers.has(VM_AUTHORIZATION_HEADER) ||
    request.headers.has(VM_ID_HEADER) ||
    request.headers.has(ROUTE_TOKEN_HEADER)
  ) {
    const auth = await authenticate(request);
    if (!auth.ok) return jsonResponse({ error: auth.reason }, 401);
    if (!auth.identity.vmId || auth.identity.machine === "chatmux") return jsonResponse({ error: "vm_bound_token_required" }, 403);
    return jsonResponse({ selectedTeamId: auth.identity.teamId, fixed: true,
      teams: [{ id: auth.identity.teamId, name: auth.identity.teamId, personal: auth.identity.teamId === auth.identity.stackUserId,
        permissions: { use: true, manageAccounts: false } }] });
  }
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return unauthorizedResponse();

      const authorized = await listTeams(user);
      let selectedTeamId: string | null = null;
      let stackSelectedTeamId: string | null = null;
      const teams = [];
      for (const team of authorized) {
        if (team.teamId === user.selectedTeamId) {
          stackSelectedTeamId = user.selectedTeamId;
        }
        teams.push({
          id: team.teamId,
          name: team.teamName,
          personal: team.personal,
          permissions: {
            use: team.use,
            manageAccounts: team.manageAccounts,
          },
        });
      }
      selectedTeamId ??= stackSelectedTeamId;
      captureCoderouterEvent({
        event: "coderouter_organization_catalog_viewed",
        ...(selectedTeamId ? { teamId: selectedTeamId } : {}),
        properties: {
          organization_count: teams.length,
          has_selected_organization: selectedTeamId !== null,
        },
      });
      return jsonResponse({ selectedTeamId, teams });
    });
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Subrouter authorization unavailable", {
        errorType: error.name,
      });
      return serviceUnavailableResponse();
    }
    throw error;
  }
}
