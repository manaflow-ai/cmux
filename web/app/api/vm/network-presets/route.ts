import { jsonResponse, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { networkPolicyCatalog } from "../../../../services/vms/networkPolicyRoute";

/** Preset quick-adds and always-allowed hosts, for the New Machine sheet and editors. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/network-presets",
    { "cmux.vm.operation": "network_presets" },
    "/api/vm/network-presets GET failed",
    async () => jsonResponse(networkPolicyCatalog()),
  );
}
