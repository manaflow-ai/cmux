import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { optionalClientIdentifier } from "../../../../../services/vms/routeInput";
import { hugeBlueInspectionMode } from "../../../../../services/vms/hugeBlueInspection";
import { inspectVmForHugeBlue } from "../../../../../services/vms/hugeBlueInspectionWorkflow";

// Mirrors VM_ROUTE_DEADLINES (services/vms/routeDeadline.ts).
export const maxDuration = 300;

/**
 * Read-only Huge Blue inspection of one of the caller's machines (#21332).
 * Answers 200 with a typed state for every reachable outcome; a machine the
 * caller cannot see is 404 in every mode. No token, route, credential or
 * command is ever returned.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/huge-blue-inspection",
    { "cmux.vm.operation": "huge_blue_inspect" },
    "/api/vm/[id]/huge-blue-inspection failed",
    async ({ user, span }) => {
      const { id } = await params;
      let deviceFingerprint: string | undefined;
      try {
        deviceFingerprint = optionalClientIdentifier(new URL(request.url).searchParams.get("deviceFingerprint"), "deviceFingerprint");
      } catch (err) {
        return jsonResponse({
          error: "invalid_request",
          message: err instanceof Error ? err.message : "Invalid inspection request.",
        }, 400);
      }
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const mode = hugeBlueInspectionMode();
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.vm.huge_blue.mode": mode });
      const run = await runVmRoute(inspectVmForHugeBlue({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        mode,
        deviceFingerprint,
      }), { request, readDeadline: { operation: "getVm" } });
      if (!run.ok) return run.response;
      setSpanAttributes(span, { "cmux.vm.huge_blue.state": run.value.state, "cmux.vm.huge_blue.reason": run.value.reasonCode });
      return jsonResponse(run.value);
    },
  );
}
