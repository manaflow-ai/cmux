import { withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { nextCursor, parseCursor, runError, runJson, RunRequestError } from "../../../../../services/runs/http";
import { listRunEvents } from "../../../../../services/runs/repository";
import { toRunEventView } from "../../../../../services/runs/view";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs/[id]/events", { "cmux.vm.operation": "run_events" }, "/api/runs events GET failed", async ({ user }) => {
    try {
      const { id } = await params;
      const url = new URL(request.url);
      const cursor = parseCursor(url.searchParams.get("after"));
      if (url.searchParams.has("after") && !cursor) return runError(new RunRequestError("run_cursor_invalid", "The event cursor is invalid.", "Use the nextCursor returned by the previous Run events response."));
      const parsedLimit = Number(url.searchParams.get("limit") ?? "100");
      const result = await listRunEvents({ runId: id, userId: user.id, afterSequence: cursor?.sequence, limit: Number.isSafeInteger(parsedLimit) ? parsedLimit : 100 });
      return runJson({ events: result.events.map(toRunEventView), nextCursor: nextCursor(result.nextSequence) });
    } catch (error) {
      return runError(error);
    }
  });
}

