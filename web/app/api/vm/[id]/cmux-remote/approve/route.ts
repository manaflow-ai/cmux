import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmResourceErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { approveVmCmuxRemoteEnrollment, runVmWorkflow } from "../../../../../../services/vms/workflows";
import { parseLenientObjectBody } from "../../../../../../services/vms/routeInput";

/**
 * Compatibility endpoint. Cloud machines serve a trusted-carrier listener
 * (reachable only inside the owner's private network), so there is no device
 * enrollment to approve: the provider answers `approved` without touching the
 * machine. Older Mac builds call this once after their first connect; the
 * route stays until every published build has stopped calling it.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/cmux-remote/approve",
    { "cmux.vm.operation": "approve_cmux_remote_enrollment" },
    "/api/vm/[id]/cmux-remote/approve failed",
    async ({ user, span }) => {
      const { id } = await params;
      const body = await parseLenientObjectBody(request);
      const raw = body.invitationId ?? body.invitation_id;
      const invitationId = typeof raw === "string" ? raw.trim() : "";
      if (!/^[A-Za-z0-9._-]{1,128}$/.test(invitationId)) {
        return jsonResponse({
          error: "invalid_request",
          message: "invitationId must be 1-128 characters of letters, numbers, dot, underscore, or dash",
        }, 400);
      }
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        const result = await runVmWorkflow(approveVmCmuxRemoteEnrollment({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          invitationId,
          callerPlanId: account.entitlements.planId,
        }));
        setSpanAttributes(span, { "cmux.vm.cmux_remote.approval_state": result.state });
        return jsonResponse(result);
      } catch (err) {
        const response = vmResourceErrorResponse(err, id);
        if (response) return response;
        throw err;
      }
    },
  );
}
