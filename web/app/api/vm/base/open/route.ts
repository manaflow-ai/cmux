import {
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { captureVmProvisionOutcome } from "../../../../../services/vms/observability";
import { VmTimingRecorder } from "../../../../../services/vms/timings";
import { runBaseRoute } from "../routeShared";


// Base open/reset cold-provisions a machine; same budget and rationale as
// POST /api/vm (see app/api/vm/route.ts).
export const maxDuration = 600;

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/base/open",
    { "cmux.vm.operation": "base.open" },
    "/api/vm/base/open POST failed",
    async ({ user, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "base.open", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => {
        timing.finish({ status: response.status });
        captureVmProvisionOutcome({ userId: user.id, operation: "base_open", response, span });
      });
      return await runBaseRoute({ request, user, operation: "open", timing });
    },
  );
}
