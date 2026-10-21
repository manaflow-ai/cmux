import { jsonResponse } from "../../../../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, RunHttpError } from "../../../../../../../services/runs/http";
import { promoteRunAttempt } from "../../../../../../../services/runs/promotion";
export function POST(request: Request, context: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id/attempts/:attemptId/promote", async (scope) => {
    if (!request.headers.get("idempotency-key")) throw new RunHttpError(400, "idempotency_key_required", "Idempotency-Key is required");
    const { id, attemptId } = await context.params;
    return jsonResponse(await promoteRunAttempt({ ...scope, runId: validRunId(id), attemptId: validRunId(attemptId) }));
  });
}
