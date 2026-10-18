import { createTeamForUser } from "../../../services/teams/admin";
import { readTeamJson } from "../../../services/teams/http";
import { teamJson, withTeamUserRoute } from "../../../services/teams/route";
import { createTeamBody } from "../../../services/teams/schemas";

/** Create a team; the creator becomes its admin and the team is selected. */
export async function POST(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams", { rateLimited: true }, async (user) => {
    const body = await readTeamJson(request, createTeamBody);
    if (!body.ok) return body.response;
    const team = await createTeamForUser(user.id, body.value.displayName);
    return teamJson({ team }, 201);
  });
}
