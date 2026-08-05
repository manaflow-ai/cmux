import {
  issueRouteToken,
  revokeRouteToken,
} from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "use");
  if (!resolved.ok) return resolved.response;
  const issued = await issueRouteToken(resolved.value.team.teamId);
  return Response.json(
    {
      teamId: resolved.value.team.teamId,
      token: issued.token,
      expiresAt: issued.expiresAt.toISOString(),
      openaiBaseUrl: "https://coderouter.dev/v1",
    },
    { headers: { "cache-control": "no-store" } },
  );
}

export async function DELETE(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "use");
  if (!resolved.ok) return resolved.response;
  const routeToken = request.headers.get("x-coderouter-route-token")?.trim();
  if (!routeToken) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  await revokeRouteToken(resolved.value.team.teamId, routeToken);
  return new Response(null, {
    status: 204,
    headers: { "cache-control": "no-store" },
  });
}
