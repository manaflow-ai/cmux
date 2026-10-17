import { withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { runError, runJson } from "../../../../../services/runs/http";
import { cancelRun } from "../../../../../services/runs/repository";

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs/[id]/cancel", { "cmux.vm.operation": "run_cancel" }, "/api/runs cancel POST failed", async ({ user }) => {
    try {
      const { id } = await params;
      return runJson(await cancelRun(id, user.id));
    } catch (error) {
      return runError(error);
    }
  });
}

