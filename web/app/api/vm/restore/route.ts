import { unauthorized, verifyRequest, type AuthedUser } from "../../../../services/vms/auth";
import { defaultProviderId } from "../../../../services/vms/drivers";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmBillingTeamErrorResponse,
  vmCreateLikeErrorResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
  vmRequiresProResponse,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import {
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../../../../services/vms/entitlements";
import { restoreVm, runVmWorkflow } from "../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../services/vms/timings";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import {
  idempotencyKeyFromRequest,
  parseRequiredObjectBody,
  providerField,
  stringField,
} from "../../../../services/vms/routeInput";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/restore",
    { "cmux.vm.operation": "restore" },
    "/api/vm/restore POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "restore", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      const parsedBody = await parseRequiredObjectBody(request, {
        operation: "restore",
        action: "Send `{ \"snapshotId\": \"...\" }`.",
      });
      if (!parsedBody.ok) return parsedBody.response;
      const body = parsedBody.body;
      if (body === null) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "Cloud VM restore expected a JSON object body.",
          action: "Send `{ \"snapshotId\": \"...\" }`.",
        });
      }
      const snapshotId = stringField(body, "snapshotId") ?? stringField(body, "snapshot_id");
      if (!snapshotId) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "`snapshotId` is required.",
          action: "Run `cmux vm snapshot <id>` first, then restore the printed snapshot id.",
          details: { field: "snapshotId" },
        });
      }
      const providerResult = providerField(body);
      if (!providerResult.ok) return providerResult.response;
      const provider = providerResult.provider ?? defaultProviderId();
      let user: AuthedUser = initialUser;
      const requestedBillingTeamId = stringField(body, "billingTeamId") ?? stringField(body, "teamId") ?? requestedVmTeamIdFromRequest(request);
      if (requestedBillingTeamId && !user.teamIds.includes(requestedBillingTeamId)) {
        let refreshedUser: AuthedUser | null;
        try {
          refreshedUser = await verifyRequest(request, { requestedTeamId: requestedBillingTeamId });
        } catch (error) {
          return authProviderErrorResponse(error, "/api/vm.restore.team-auth");
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
      setSpanAttributes(span, {
        "cmux.snapshot.id": snapshotId,
        "cmux.vm.provider": provider,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });
      try {
        const restored = await runVmWorkflow(restoreVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          provider,
          snapshotId,
          idempotencyKey,
          timing,
        }));
        return jsonResponse({
          id: restored.providerVmId,
          provider: restored.provider,
          image: restored.image,
          imageVersion: restored.imageVersion,
          status: restored.status,
          createdAt: restored.createdAt,
        });
      } catch (err) {
        const response = vmCreateLikeErrorResponse(err, {
          operation: "restore",
          planId: entitlements.planId,
          retryAction: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before restoring another.",
        });
        if (response) return response;
        throw err;
      }
    },
  );
}
