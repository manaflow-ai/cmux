import { jsonResponse, withAuthedVmApiRoute } from "@/services/vms/routeHelpers";
import { runVmRoute } from "@/services/vms/routeWorkflow";
import { listVmAccessGrants } from "@/services/vms/workflows";

/**
 * The Macs with Cloud VM network access, for the dashboard's Cloud page.
 * Grants belong to the user, not to a billing team, so no team scope is
 * resolved: an ambiguous team selection must not hide the user's own Macs.
 */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/access-grants",
    { "cmux.vm.operation": "list_access_grants" },
    "/api/vm/access-grants failed",
    async ({ user }) => {
      const devices = await runVmRoute(listVmAccessGrants({ userId: user.id }), { request });
      if (!devices.ok) return devices.response;
      return jsonResponse({ devices: devices.value }, 200, { "cache-control": "private, no-store" });
    },
  );
}
