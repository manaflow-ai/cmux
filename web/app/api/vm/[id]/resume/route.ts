import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  vmWorkflowErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { resumeVmForAttach, runVmWorkflow } from "../../../../../services/vms/workflows";

/** Recovery-only wake used after a private direct attach cannot dial. */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/resume",
    { "cmux.vm.operation": "attach_resume" },
    "/api/vm/[id]/resume failed",
    async ({ user }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      try {
        await runVmWorkflow(resumeVmForAttach({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
        }));
        return jsonResponse({ ok: true });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        const translated = await vmWorkflowErrorResponse(err);
        if (translated) return translated;
        throw err;
      }
    },
  );
}
