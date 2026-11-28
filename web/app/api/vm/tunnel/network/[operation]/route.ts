import { defaultProviderId } from "../../../../../../services/vms/drivers";
import { jsonResponse, vmErrorResponse, withAuthedVmApiRoute } from "../../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { attachVmTunnelNetwork, detachVmTunnelNetwork, rotateVmTunnelKey, isWireGuardPublicKey } from "../../../../../../services/vms/workflows";
import { optionalString, parseLenientObjectBody } from "../../../../../../services/vms/routeInput";

type Params = { operation: string };
function required(body: Record<string, unknown>, key: string): string | Response {
  const value = optionalString(body[key]);
  return value || vmErrorResponse({ error: "vm_invalid_tunnel_request", status: 400, message: `${key} is required.`, action: `Pass ${key} in the request body.` });
}

export async function POST(request: Request, { params }: { params: Promise<Params> }): Promise<Response> {
  const { operation } = await params;
  return withAuthedVmApiRoute(request, "/api/vm/tunnel/network/[operation]", { "cmux.vm.operation": `tunnel_${operation}` }, "/api/vm/tunnel/network failed", async ({ user }) => {
    if (operation !== "attach" && operation !== "detach" && operation !== "rotate-key") return vmErrorResponse({ error: "vm_unknown_tunnel_operation", status: 404, message: "Unknown tunnel network operation.", action: "Use attach, detach, or rotate-key." });
    const body = await parseLenientObjectBody(request);
    const deviceFingerprint = required(body, "deviceFingerprint"); if (deviceFingerprint instanceof Response) return deviceFingerprint;
    const tunnelPurpose = optionalString(body.tunnelPurpose) ?? "browser";
    if (tunnelPurpose !== "browser" && tunnelPurpose !== "terminal") return vmErrorResponse({ error: "vm_invalid_tunnel_request", status: 400, message: "tunnelPurpose must be browser or terminal.", action: "Pass a supported tunnel purpose." });
    if (operation === "rotate-key") {
      const clientPublicKey = required(body, "clientPublicKey");
      if (clientPublicKey instanceof Response || !isWireGuardPublicKey(clientPublicKey)) return vmErrorResponse({ error: "vm_tunnel_invalid_key", status: 400, message: "clientPublicKey must be a WireGuard public key.", action: "Generate a new keypair and pass its public key." });
      const result = await runVmRoute(rotateVmTunnelKey({ userId: user.id, provider: defaultProviderId(), deviceFingerprint, tunnelPurpose, clientPublicKey }), { request });
      if (!result.ok) return result.response;
      return jsonResponse(result.value);
    }
    const networkId = required(body, "networkId"); if (networkId instanceof Response) return networkId;
    if (operation === "attach") {
      const result = await runVmRoute(attachVmTunnelNetwork({ userId: user.id, provider: defaultProviderId(), deviceFingerprint, tunnelPurpose, networkId }), { request });
      if (!result.ok) return result.response;
      return jsonResponse(result.value);
    }
    if (operation === "detach") {
      const result = await runVmRoute(detachVmTunnelNetwork({ userId: user.id, provider: defaultProviderId(), deviceFingerprint, tunnelPurpose, networkId }), { request });
      if (!result.ok) return result.response;
      return jsonResponse(result.value);
    }
    return vmErrorResponse({ error: "vm_unknown_tunnel_operation", status: 404, message: "Unknown tunnel network operation.", action: "Use attach, detach, or rotate-key." });
  });
}
