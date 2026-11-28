import { acceptTeamInvitationCode } from "../../../../services/teams/accept";
import { readTeamJson } from "../../../../services/teams/http";
import { teamJson, withTeamUserRoute } from "../../../../services/teams/route";
import { acceptBody } from "../../../../services/teams/schemas";

/** Accept a Stack email invitation and apply the role stored for it. */
export async function POST(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams/accept", { rateLimited: true }, async (user) => {
    const body = await readTeamJson(request, acceptBody);
    if (!body.ok) return body.response;
    const { teamId } = await acceptTeamInvitationCode(request, user.id, body.value.code);
    return teamJson({ teamId });
  });
}
