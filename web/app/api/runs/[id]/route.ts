import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, runNotFound } from "../../../../services/runs/legacy/http";
import { readRunSnapshot } from "../../../../services/runs/legacy/repository";
import { runReceipt } from "../../../../services/runs/legacy/view";

export function GET(request: Request, context: { params: Promise<{ id: string }> }): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id", async (scope) => {
    const { id } = await context.params;
    const snapshot = await readRunSnapshot(validRunId(id), scope);
    if (!snapshot) runNotFound();
    return jsonResponse(runReceipt(snapshot));
  });
}
