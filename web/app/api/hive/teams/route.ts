import {
  personalHiveTeamID,
  withAuthedHiveApiRoute,
} from "../../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive/teams",
    { "cmux.hive.operation": "list_teams" },
    "/api/hive/teams GET failed",
    async ({ user, hiveTeamID }) => {
      const personalTeamID = personalHiveTeamID(user);
      const userTeams = user.teams.map((team) => ({
        id: team.id,
        display_name: team.displayName ?? team.slug ?? team.id,
        is_personal: team.isPersonal,
      }));
      const hasPersonalTeam = userTeams.some((team) => team.id === personalTeamID);
      const teams = [
        ...(hasPersonalTeam
          ? []
          : [
            {
              id: personalTeamID,
              display_name: "Personal",
              is_personal: true,
            },
          ]),
        ...userTeams,
      ];
      return jsonResponse({
        teams,
        default_team_id: hiveTeamID,
        selected_team_id: user.selectedTeamId,
      });
    },
  );
}
