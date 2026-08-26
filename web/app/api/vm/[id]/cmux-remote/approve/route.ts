import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../../services/vms/errors";
import { approveVmCmuxRemoteEnrollment, runVmWorkflow } from "../../../../../../services/vms/workflows";

/**
 * Approves the cmux-tui device enrollment that a prior `attach-endpoint`
 * (`transport: "cmux-remote"`) invited. The control plane is the daemon owner: it
 * minted the invitation for this authenticated user, so approving the pending claim
 * is the honest encoding of "the web tier already authenticated this device". Returns
 * `state: "pending"` until the client has connected with the invitation; callers poll.
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
      const body = await parseBody(request);
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
        }));
        setSpanAttributes(span, { "cmux.vm.cmux_remote.approval_state": result.state });
        return jsonResponse(result);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

async function parseBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
