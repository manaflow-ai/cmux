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
import {
  coderouterOrganizationFromCookieHeader,
} from "../../../../services/coderouter/organizationScope";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";


export async function GET(request: Request): Promise<Response> {
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return unauthorized();

      const authorized = authorizedSubrouterTeams(user);
      const scopedTeamId = coderouterOrganizationFromCookieHeader(
        request.headers.get("cookie"),
        user.id,
      );
      let selectedTeamId: string | null = null;
      let stackSelectedTeamId: string | null = null;
      const teams = [];
      for (const team of authorized) {
        if (team.teamId === scopedTeamId) selectedTeamId = scopedTeamId;
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
