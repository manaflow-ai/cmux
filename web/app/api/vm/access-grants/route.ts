import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "@/services/vms/routeHelpers";
import { runVmRoute } from "@/services/vms/routeWorkflow";
import { listVmAccessGrants } from "@/services/vms/workflows";

/** The Macs with Cloud VM network access, for the dashboard's Cloud page. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/access-grants",
    { "cmux.vm.operation": "list_access_grants" },
    "/api/vm/access-grants failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const devices = await runVmRoute(listVmAccessGrants({ userId: user.id }), { request });
      if (!devices.ok) return devices.response;
      return jsonResponse({ devices: devices.value }, 200, { "cache-control": "private, no-store" });
    },
  );
}
