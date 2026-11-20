import { and, asc, eq, gt } from "drizzle-orm";
import { cloudDb } from "../../../../../db/client";
import { runEvents } from "../../../../../db/schema";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { withRunRoute, validRunId, runNotFound, RunHttpError } from "../../../../../services/runs/legacy/http";
import { readRunSnapshot } from "../../../../../services/runs/legacy/repository";

export function GET(request: Request, context: { params: Promise<{ id: string }> }): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id/events", async (scope) => {
    const { id } = await context.params;
    const snapshot = await readRunSnapshot(validRunId(id), scope);
    if (!snapshot) runNotFound();
    const raw = new URL(request.url).searchParams.get("after") ?? "-1";
    if (!/^-?\d{1,10}$/.test(raw) || Number(raw) < -1) throw new RunHttpError(400, "run_invalid_cursor", "Invalid Run event cursor");
    const events = await cloudDb().select().from(runEvents).where(and(eq(runEvents.runId, id), gt(runEvents.sequence, Number(raw)))).orderBy(asc(runEvents.sequence)).limit(200);
    return jsonResponse({ events, nextCursor: String(events.at(-1)?.sequence ?? Number(raw)) });
  });
}
