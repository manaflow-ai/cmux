import { unauthorized, verifyRequest, type AuthedUser } from "../../../../services/vms/auth";
import { assertVmCreateEnabled } from "../../../../services/vms/config";
import { defaultProviderId } from "../../../../services/vms/drivers";
import { isVmCreateDisabledError } from "../../../../services/vms/errors";
import { captureVmProvisionOutcome } from "../../../../services/vms/observability";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmCreateLikeErrorResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
  resolveVmProvisioningAccountScope,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import { restoreVm, runVmWorkflow } from "../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../services/vms/timings";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import {
  idempotencyKeyFromRequest,
  parseRequiredObjectBody,
  providerField,
  stringField,
} from "../../../../services/vms/routeInput";

// Restore cold-provisions a machine from a snapshot; same budget and
// rationale as POST /api/vm (see app/api/vm/route.ts).
export const maxDuration = 600;

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/restore",
    { "cmux.vm.operation": "restore" },
    "/api/vm/restore POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "restore", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => {
        timing.finish({ status: response.status });
        captureVmProvisionOutcome({ userId: initialUser.id, operation: "restore", response, span });
      });
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
      const account = await resolveVmProvisioningAccountScope(user, request, { requestedBillingTeamId });
      if (!account.ok) return account.response;
      const entitlements = account.entitlements;

      // Restore provisions a brand-new machine on `provider`; check the
      // environment kill switch only after the paid-plan boundary so a free
      // caller cannot be diverted into provider/config work first.
      const provider = providerResult.provider ?? defaultProviderId();
      try {
        assertVmCreateEnabled(provider);
      } catch (err) {
        if (isVmCreateDisabledError(err)) {
          return vmErrorResponse({
            error: "vm_create_disabled",
            status: 503,
            message: "Cloud VM creation is disabled for this environment.",
            action: "Ask an admin to enable Cloud VM creation, then retry.",
            reason: "Cloud VM creation is disabled.",
            phase: "create",
            retryable: true,
          });
        }
        throw err;
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
          retryAction: "Run `cmux vm ls`, then delete an active VM with `cmux vm rm <id>` before restoring another.",
        });
        if (response) return response;
        throw err;
      }
    },
  );
}
