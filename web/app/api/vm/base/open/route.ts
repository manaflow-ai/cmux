import {
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { VmTimingRecorder } from "../../../../../services/vms/timings";
import { runBaseRoute } from "../routeShared";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/base/open",
    { "cmux.vm.operation": "base.open" },
    "/api/vm/base/open POST failed",
    async ({ user, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "base.open", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      return await runBaseRoute({ request, user, operation: "open", timing });
    },
  );
}
