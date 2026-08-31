import { unauthorized, verifyRequest, type AuthedUser } from "../../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  requestedVmTeamIdFromRequest,
  vmBillingTeamErrorResponse,
  vmCreateLikeErrorResponse,
  withAuthedVmApiRoute,
  vmRequiresProResponse,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import {
  isVmNotFoundError,
} from "../../../../../services/vms/errors";
import {
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../../../../../services/vms/entitlements";
import { forkVm, runVmWorkflow } from "../../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../../services/vms/timings";
import { authProviderErrorResponse } from "../../../../../services/vms/authErrors";
import {
  idempotencyKeyFromRequest,
  parseOptionalObjectBody,
  stringField,
} from "../../../../../services/vms/routeInput";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/fork",
    { "cmux.vm.operation": "fork" },
    "/api/vm/[id]/fork POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "fork", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      const parsedBody = await parseOptionalObjectBody(request, {
        operation: "fork",
        action: "Send `{}` or `{ \"name\": \"before-agent\" }`.",
      });
      if (!parsedBody.ok) return parsedBody.response;
      const body = parsedBody.body;
      const { id } = await params;
      let user: AuthedUser = initialUser;
      const requestedBillingTeamId = stringField(body, "billingTeamId") ?? stringField(body, "teamId") ?? requestedVmTeamIdFromRequest(request);
      if (requestedBillingTeamId && !user.teamIds.includes(requestedBillingTeamId)) {
        let refreshedUser: AuthedUser | null;
        try {
          refreshedUser = await verifyRequest(request, { requestedTeamId: requestedBillingTeamId });
        } catch (error) {
          return authProviderErrorResponse(error, "/api/vm.fork.team-auth");
        }
        if (!refreshedUser) return unauthorized();
        user = refreshedUser;
      }
      let entitlements;
      try {
        entitlements = resolveVmEntitlements(user, process.env, {
          requestedBillingTeamId,
          requireTeam: true,
        });
      } catch (err) {
        if (isVmBillingTeamResolutionError(err)) return vmBillingTeamErrorResponse(err);
        throw err;
      }
      if (isVmProGateBlocked(entitlements)) {
        return vmRequiresProResponse();
      }
      const idempotencyKey = idempotencyKeyFromRequest(request);
      const name = stringField(body, "name");
      setSpanAttributes(span, {
        "cmux.vm.id": id,
        "cmux.billing.team_id_set": !!entitlements.billingTeamId,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });
      try {
        const result = await runVmWorkflow(forkVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          teamIds: user.teamIds,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          providerVmId: id,
          name,
          idempotencyKey,
          timing,
        }));
        return jsonResponse({
          snapshotId: result.snapshot?.id ?? null,
          id: result.fork.providerVmId,
          provider: result.fork.provider,
          image: result.fork.image,
          imageVersion: result.fork.imageVersion,
          status: result.fork.status,
          createdAt: result.fork.createdAt,
        });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        const response = vmCreateLikeErrorResponse(err, {
          operation: "fork",
          planId: entitlements.planId,
          retryAction: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before forking another.",
        });
        if (response) return response;
        throw err;
      }
    },
  );
}
