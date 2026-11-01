import { after } from "next/server";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, runNotFound } from "../../../../../services/runs/legacy/http";
import { readRunSnapshot } from "../../../../../services/runs/legacy/repository";
import { cancelRun } from "../../../../../services/runs/legacy/worker";
import { processRunQueue } from "../../../../../services/runs/legacy/runner";
import { runReceipt } from "../../../../../services/runs/legacy/view";
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
