import { transferAccount } from "../../../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../../../services/coderouter/requestContext";
import { authorizedSubrouterTeams } from "../../../../../../services/subrouter/routeHelpers";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function POST(request: Request, context: { params: Promise<{ accountId: string }> }): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "manage");
  if (!resolved.ok) return resolved.response;
  const { accountId } = await context.params;
  if (!UUID.test(accountId)) return Response.json({ error: "invalid_request" }, { status: 400 });
  let body: unknown;
  try { body = await request.json(); } catch { return Response.json({ error: "invalid_request" }, { status: 400 }); }
  const destinationTeamId = typeof body === "object" && body !== null && "destinationTeamId" in body && typeof (body as { destinationTeamId?: unknown }).destinationTeamId === "string"
    ? (body as { destinationTeamId: string }).destinationTeamId.trim() : "";
  const destination = (await authorizedSubrouterTeams(resolved.value.user)).find((team) => team.teamId === destinationTeamId && team.manageAccounts);
  if (!destination || destinationTeamId === resolved.value.team.teamId) return Response.json({ error: "destination_forbidden" }, { status: 403 });
  try {
    const moved = await transferAccount({ accountId, sourceTeamId: resolved.value.team.teamId, destinationTeamId, stackUserId: resolved.value.user.id });
    return moved ? Response.json({ accountId, sourceTeamId: resolved.value.team.teamId, destinationTeamId }) : Response.json({ error: "not_found" }, { status: 404 });
  } catch {
    return Response.json({ error: "account_transfer_unavailable", retryable: true }, { status: 503, headers: { "retry-after": "5" } });
  }
}
