import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
} from "../../../../services/vms/auth";
import { subrouterTeamAllowed } from "../../../../services/subrouter/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const user = await verifyRequest(request, {
    allowCookie: true,
    listAllTeams: true,
  });
  if (!user) return unauthorized();

  const teams = user.teams
    .filter((team) => subrouterTeamAllowed(team.id))
    .map((team) => ({
    id: team.id,
    name: team.displayName ?? team.id,
    personal: false,
    permissions: {
      use: team.subrouterUse ?? false,
      manageAccounts: team.subrouterManageAccounts ?? false,
    },
  }));
  if (
    subrouterTeamAllowed(user.id) &&
    !teams.some((team) => team.id === user.id)
  ) {
    teams.push({
      id: user.id,
      name: user.displayName ?? user.primaryEmail ?? user.id,
      personal: true,
      permissions: {
        use: user.personalSubrouterUse ?? false,
        manageAccounts: user.personalSubrouterManageAccounts ?? false,
      },
    });
  }

  return jsonResponse({
    selectedTeamId: teams.some(
      (team) => team.id === (user.selectedTeamId ?? user.billingTeamId),
    )
      ? user.selectedTeamId ?? user.billingTeamId
      : null,
    teams,
  });
}
