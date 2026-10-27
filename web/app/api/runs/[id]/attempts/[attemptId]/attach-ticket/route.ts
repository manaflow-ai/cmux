import { jsonResponse } from "../../../../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, RunHttpError } from "../../../../../../../services/runs/http";
import { runAttachTicket } from "../../../../../../../services/runs/attach";
import { runCloudClient } from "../../../../../../../services/runs/cloudClient";
export const maxDuration = 300;
export function POST(request: Request, context: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id/attempts/:attemptId/attach-ticket", async (scope) => {
    const { id, attemptId } = await context.params;
    const body = await request.json().catch(() => ({}));
    if (body.ticket !== undefined && (typeof body.ticket !== "string" || body.ticket.length > 128)) throw new RunHttpError(400, "invalid_attach_ticket", "Invalid attach ticket");
    const target = await runAttachTicket({ ...scope, runId: validRunId(id), attemptId: validRunId(attemptId), ticket: body.ticket, ttlMs: body.ttlMs });
    let response: Response;
    if (!target.redeemed) response = jsonResponse(target, 201);
    else {
      const client = await runCloudClient(scope.userId, scope.ownerTeamId);
      const endpoint = await client("POST", `/api/vm/${encodeURIComponent(target.providerVmId)}/attach-endpoint`, { transport: "cmux-remote" });
      response = jsonResponse({ ...target, endpoint, transport: endpoint.transport, route: endpoint.route, token: endpoint.token, session: endpoint.session, expiresAtUnix: endpoint.expiresAtUnix });
    }
    response.headers.set("cache-control", "no-store");
    return response;
  });
}
