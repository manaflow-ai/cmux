import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import {
  actionRunTeamErrorResponseDetails,
  isActionRunError,
  runAction,
  type ActionRunRequest,
} from "../../../../services/actions/runner";
import { isVmBillingTeamResolutionError } from "../../../../services/vms/entitlements";
import { setSpanAttributes } from "../../../../services/telemetry";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/actions/run",
    { "cmux.actions.operation": "run" },
    "/api/actions/run POST failed",
    async ({ user, span }) => {
      let rawBody: unknown;
      try {
        rawBody = await request.json();
      } catch {
        return vmErrorResponse({
          error: "actions_invalid_json",
          status: 400,
          message: "Action run expected a JSON object body.",
          action: "Send JSON like `{ \"action\": \"hexclave/stack-auth:fresh-env\" }`.",
        });
      }
      if (rawBody === null || typeof rawBody !== "object" || Array.isArray(rawBody)) {
        return vmErrorResponse({
          error: "actions_invalid_request",
          status: 400,
          message: "Action run body must be a JSON object.",
          action: "Send JSON like `{ \"action\": \"hexclave/stack-auth:fresh-env\" }`.",
        });
      }

      const body = rawBody as ActionRunRequest;
      setSpanAttributes(span, {
        "cmux.actions.id": typeof body.action === "string" ? body.action : "",
        "cmux.actions.dry_run": body.dryRun === true,
      });

      try {
        const result = await runAction({
          request: body,
          user,
          requestedBillingTeamId: requestedVmTeamIdFromRequest(request),
        });
        return jsonResponse(result);
      } catch (err) {
        if (isActionRunError(err)) {
          return vmErrorResponse({
            error: err.code,
            status: err.status,
            message: err.message,
            action: err.action,
            details: err.details,
          });
        }
        if (isVmBillingTeamResolutionError(err)) {
          return vmErrorResponse(actionRunTeamErrorResponseDetails(err));
        }
        throw err;
      }
    },
  );
}
