import { previewTeamInviteLink, redeemTeamInviteLink } from "../../../../../services/teams/links";
import { teamJson, withTeamUserRoute } from "../../../../../services/teams/route";

type RouteContext = { params: Promise<{ token: string }> };

const ROUTE = "/api/teams/join/[token]";

export async function GET(request: Request, context: RouteContext): Promise<Response> {
  const { token } = await context.params;
  return withTeamUserRoute(request, ROUTE, { rateLimited: true }, async (user) =>
    teamJson(await previewTeamInviteLink(user.id, token)));
}

export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { token } = await context.params;
  return withTeamUserRoute(request, ROUTE, { rateLimited: true }, async (user) =>
    teamJson(await redeemTeamInviteLink(user.id, token)));
}
