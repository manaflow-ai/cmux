import { jsonResponse, resolveVmRouteAccountScope, vmErrorResponse, withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { prepareScpEndpoint, scpAnswerBudgetMs } from "../../../../../services/vms/workflows";
import { parseSshPublicKey } from "../../../../../services/vms/drivers/scp";
import { vmModelPlaneRevoker } from "../../../../../services/vms/modelPlaneGateway";

// Mirrors VM_ROUTE_DEADLINES (services/vms/routeDeadline.ts): work past the
// route's answer deadline continues through after() until this limit.
export const maxDuration = 300;

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/[id]/scp-endpoint", { "cmux.vm.operation": "prepare_scp" }, "/api/vm/[id]/scp-endpoint failed", async ({ user, span, routeStartedAtMs }) => {
    let publicKey: string;
    try {
      const body = await request.json();
      if (typeof body?.publicKey !== "string" || body.publicKey.length > 512) throw new Error("Invalid key");
      publicKey = parseSshPublicKey(body.publicKey);
    } catch {
      return vmErrorResponse({ error: "vm_invalid_ssh_key", status: 400, message: "Cloud file transfer requires one Ed25519 public key.", action: "Run cmux vm push again to create a new transfer key." });
    }
    const { id } = await params;
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    setSpanAttributes(span, { "cmux.vm.id": id, "cmux.transfer.transport": "wireguard-scp" });
    const run = await runVmRoute(prepareScpEndpoint({
      userId: user.id, billingTeamId: account.entitlements.billingTeamId,
      callerPlanId: account.entitlements.planId, maxActiveVms: account.entitlements.maxActiveVms,
      entitlementOverride: account.entitlements.override, teamIds: user.teamIds, providerVmId: id, publicKey,
      // Measured from the request's start: the Mac client's clock started when it sent the request.
      answerWithinMs: scpAnswerBudgetMs(performance.now() - routeStartedAtMs),
      modelPlane: vmModelPlaneRevoker(),
    }), { request });
    if (!run.ok) return run.response;
    return jsonResponse(run.value);
  });
}
