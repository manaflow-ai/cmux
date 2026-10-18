import { defaultProviderId } from "../../../../services/vms/drivers";
import { jsonResponse, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../services/vms/routeWorkflow";
import { listVmNetworks } from "../../../../services/vms/workflows";

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/network", { "cmux.vm.operation": "network_list" }, "/api/vm/network GET failed", async ({ user }) => {
    const result = await runVmRoute(listVmNetworks({ userId: user.id, provider: defaultProviderId() }), { request });
    if (!result.ok) return result.response;
    return jsonResponse({ networks: result.value });
  });
}
