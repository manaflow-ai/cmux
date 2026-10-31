import { createTeamForUser } from "../../../services/teams/admin";
import { readTeamJson } from "../../../services/teams/http";
import { listTeamsForUser } from "../../../services/teams/list";
import { teamJson, withTeamUserRoute } from "../../../services/teams/route";
import { createTeamBody } from "../../../services/teams/schemas";

/** The signed-in user's teams, each with their role and capabilities. */
export async function GET(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams", {}, async (user) => teamJson(await listTeamsForUser(user.id)));
}

/** Create a team; the creator becomes its admin and the team is selected. */
export async function POST(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams", { rateLimited: true }, async (user) => {
    const body = await readTeamJson(request, createTeamBody);
    if (!body.ok) return body.response;
    const team = await createTeamForUser(user.id, body.value.displayName);
    return teamJson({ team }, 201);
  });
}
