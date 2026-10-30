import { runError, runJson, RunRequestError } from "../../../../../../../services/runs/http";
import {
  promoteRunAttempt,
  runAttemptPromotionDependencies,
} from "../../../../../../../services/runs/promotion";
import { withAuthedVmApiRoute } from "../../../../../../../services/vms/routeHelpers";

/** Promote a completed fan-out attempt into a persistent devbox runtime. */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string; attemptId: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/runs/[id]/attempts/[attemptId]/promote",
    { "cmux.vm.operation": "run_attempt_promote" },
    "/api/runs attempt promotion POST failed",
    async ({ user }) => {
      const { id, attemptId } = await params;
      const requestKey = request.headers.get("idempotency-key")?.trim()
        || request.headers.get("x-cmux-idempotency-key")?.trim()
        || "";
      if (!requestKey || requestKey.length > 128) {
        return noStore(runError(new RunRequestError("run_promotion_idempotency_required",
          "Idempotency-Key is required for attempt promotion.",
          "Add an Idempotency-Key header of at most 128 characters and retry.")));
      }
      try {
        const promotion = await promoteRunAttempt({
          userId: user.id,
          runId: id,
          attemptId,
          requestKey,
          dependencies: runAttemptPromotionDependencies(),
        });
        return noStore(runJson(promotion, 200));
      } catch (error) {
        return noStore(runError(error));
      }
    },
  );
}

function noStore(response: Response): Response {
  response.headers.set("cache-control", "no-store");
  return response;
}

