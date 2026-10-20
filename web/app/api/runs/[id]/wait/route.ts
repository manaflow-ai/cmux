import { withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { runError, runJson } from "../../../../../services/runs/http";
import { waitForRun } from "../../../../../services/runs/repository";
import { toRunSnapshotView } from "../../../../../services/runs/view";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs/[id]/wait", { "cmux.vm.operation": "run_wait" }, "/api/runs wait GET failed", async ({ user }) => {
    try {
      const { id } = await params;
      const waitMs = Number(new URL(request.url).searchParams.get("timeoutMs") ?? "0");
      return runJson(toRunSnapshotView(await waitForRun(id, user.id, Number.isFinite(waitMs) ? waitMs : 0)));
    } catch (error) {
      return runError(error);
    }
  });
}

