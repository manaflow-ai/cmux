import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  isSubrouterAuthorizationError,
  unauthorized,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "../../../../services/vms/auth";
import {
  authorizedSubrouterTeams,
  serviceUnavailableResponse,
} from "../../../../services/subrouter/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return unauthorized();

      const authorized = await authorizedSubrouterTeams(user);
      const teams = authorized.map((team) => ({
        id: team.teamId,
        name: team.teamName,
        personal: team.personal,
        permissions: {
          use: team.use,
          manageAccounts: team.manageAccounts,
        },
      }));

      return jsonResponse({
        selectedTeamId: user.selectedTeamId && teams.some(
          (team) => team.id === user.selectedTeamId,
        )
          ? user.selectedTeamId
          : null,
        teams,
      });
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
