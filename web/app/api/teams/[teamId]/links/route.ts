import { readTeamJson } from "../../../../../services/teams/http";
import { createTeamInviteLink } from "../../../../../services/teams/links";
import { teamInviteLinkUrl } from "../../../../../services/teams/origin";
import { teamJson, withTeamAccessRoute, type TeamRouteParams } from "../../../../../services/teams/route";
import { createLinkBody } from "../../../../../services/teams/schemas";

type RouteContext = { params: TeamRouteParams };

/** Create a reusable member-only link. The raw token appears only in this response. */
export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withTeamAccessRoute(
    request,
    "/api/teams/[teamId]/links",
    teamId,
    { admin: true, permission: "inviteMembers", rateLimited: true },
    async (access) => {
      const body = await readTeamJson(request, createLinkBody);
      if (!body.ok) return body.response;
      const { link, token } = await createTeamInviteLink(access, body.value);
      return teamJson({ link, url: teamInviteLinkUrl(request, token) }, 201);
    },
  );
}
