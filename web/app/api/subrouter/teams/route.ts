import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
} from "../../../../services/vms/auth";
import {
  authorizedSubrouterTeams,
} from "../../../../services/subrouter/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const user = await verifyRequest(request, {
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
    selectedTeamId: teams.some(
      (team) => team.id === (user.selectedTeamId ?? user.billingTeamId),
    )
      ? user.selectedTeamId ?? user.billingTeamId
      : null,
    teams,
  });
}
