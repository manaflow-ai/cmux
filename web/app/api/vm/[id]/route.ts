import {
  jsonResponse,
  notFoundVm,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../services/vms/errors";
import { destroyVm, runVmWorkflow } from "../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]",
    { "cmux.vm.operation": "destroy" },
    "/api/vm/[id] DELETE failed",
    async ({ user, span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        await runVmWorkflow(destroyVm({ userId: user.id, providerVmId: id }));
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
      return jsonResponse({ ok: true });
    },
  );
}
