import {
  isDevboxNotFoundError,
  pauseDevbox,
  runDevboxWorkflow,
} from "../../../../services/vms/devbox";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { devboxNotFoundResponse } from "../shared";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/devbox/pause",
    { "cmux.vm.operation": "devbox_pause" },
    "/api/devbox/pause POST failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      try {
        const devbox = await runDevboxWorkflow(pauseDevbox({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
        }));
        return jsonResponse({ devbox });
      } catch (err) {
        if (isDevboxNotFoundError(err)) return devboxNotFoundResponse();
        throw err;
      }
    },
  );
}
