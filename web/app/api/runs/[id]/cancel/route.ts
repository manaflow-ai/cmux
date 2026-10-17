import { withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { runError, runJson } from "../../../../../services/runs/http";
import { cancelRun, getRun } from "../../../../../services/runs/repository";
import { cancelActiveCloudVmAttempts } from "../../../../../services/runs/dogfood";

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs/[id]/cancel", { "cmux.vm.operation": "run_cancel" }, "/api/runs cancel POST failed", async ({ user }) => {
    try {
      const { id } = await params;
      await cancelRun(id, user.id);
      await cancelActiveCloudVmAttempts({ runId: id, userId: user.id });
      // The cancellation worker may have raced a terminal receipt; return the
      // post-fence snapshot so clients do not remain stuck on cancelling.
      return runJson(await getRun(id, user.id));
    } catch (error) {
      return runError(error);
    }
  });
}

