import { after } from "next/server";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, runNotFound } from "../../../../../services/runs/http";
import { readRunSnapshot } from "../../../../../services/runs/repository";
import { cancelRun } from "../../../../../services/runs/worker";
import { processRunQueue } from "../../../../../services/runs/runner";
import { runReceipt } from "../../../../../services/runs/view";
export const maxDuration = 960;
export function POST(request: Request, context: { params: Promise<{ id: string }> }): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id/cancel", async (scope) => {
    const { id } = await context.params;
    if (!await readRunSnapshot(validRunId(id), scope)) runNotFound();
    await cancelRun({ runId: id });
    after(() => processRunQueue({ runId: id, ownerTeamId: scope.ownerTeamId }));
    const snapshot = await readRunSnapshot(id, scope);
    if (!snapshot) runNotFound();
    return jsonResponse(runReceipt(snapshot));
  });
}
