import { listReceivedInvitations } from "../../../../services/teams/received";
import { teamJson, withTeamUserRoute } from "../../../../services/teams/route";
import { verifyPolledReadRequest } from "../../../../services/vms/auth";

/**
 * Pending invitations addressed to the signed-in user's verified emails.
 * A read-only poll: a fresh identity snapshot proves the user id without
 * Stack (see `verifyPolledReadRequest`); the verified emails are still read
 * from Stack on every request.
 */
export async function GET(request: Request): Promise<Response> {
  return withTeamUserRoute(request, "/api/teams/invitations", {
    verify: (value) => verifyPolledReadRequest(value),
  }, async (user) =>
    teamJson({ invitations: await listReceivedInvitations(user.id) }));
}
