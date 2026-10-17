import { withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { runError, runJson } from "../../../../services/runs/http";
import { getRun } from "../../../../services/runs/repository";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs/[id]", { "cmux.vm.operation": "run_snapshot" }, "/api/runs GET failed", async ({ user }) => {
    try {
      const { id } = await params;
      const snapshot = await getRun(id, user.id);
      return runJson(snapshot);
    } catch (error) {
      return runError(error);
    }
  });
}

