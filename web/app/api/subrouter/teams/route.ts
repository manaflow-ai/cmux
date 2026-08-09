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
      const preferredTeamId = user.selectedTeamId;
      let selectedTeamId: string | null = null;
      const teams = [];
      for (const team of authorized) {
        if (team.teamId === preferredTeamId) selectedTeamId = preferredTeamId;
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
