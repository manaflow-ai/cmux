import { jsonResponse, resolveVmRouteAccountScope, vmErrorResponse, withAuthedVmApiRoute } from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { prepareShellEndpoint } from "../../../../../services/vms/workflows";
import { parseSshPublicKey } from "../../../../../services/vms/drivers/scp";
import { vmModelPlaneRevoker } from "../../../../../services/vms/modelPlaneGateway";

/**
 * Rescue shell: authorizes one short-lived Ed25519 key that may open a PTY as
 * cmux over the private network. The client makes the key pair, keeps the
 * private key, and pins `hostPublicKey`. Answer: {host, port, username,
 * hostPublicKey, expiresAtUnix}.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/[id]/shell-endpoint", { "cmux.vm.operation": "prepare_shell" }, "/api/vm/[id]/shell-endpoint failed", async ({ user, span }) => {
    let publicKey: string;
    try {
      const body = await request.json();
      if (typeof body?.publicKey !== "string" || body.publicKey.length > 512) throw new Error("Invalid key");
      publicKey = parseSshPublicKey(body.publicKey);
    } catch {
      return vmErrorResponse({ error: "vm_invalid_ssh_key", status: 400, message: "A Cloud VM shell requires one Ed25519 public key.", action: "Open the rescue shell again to create a new key." });
    }
    const { id } = await params;
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    setSpanAttributes(span, { "cmux.vm.id": id, "cmux.shell.transport": "wireguard-ssh" });
    const run = await runVmRoute(prepareShellEndpoint({
      userId: user.id, billingTeamId: account.entitlements.billingTeamId,
      callerPlanId: account.entitlements.planId, maxActiveVms: account.entitlements.maxActiveVms,
      teamIds: user.teamIds, providerVmId: id, publicKey,
      modelPlane: vmModelPlaneRevoker(),
    }), { request });
    if (!run.ok) return run.response;
    return jsonResponse(run.value);
  });
}
