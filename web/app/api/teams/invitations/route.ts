import { listReceivedInvitations } from "../../../../services/teams/received";
import { teamJson, withTeamUserRoute } from "../../../../services/teams/route";

/** Pending invitations addressed to the signed-in user's verified emails. */
export async function GET(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams/invitations", {}, async (user) =>
    teamJson({ invitations: await listReceivedInvitations(user.id) }));
}
