// Usage for the machine a VM-bound route token belongs to. cmux-tui inside
// the VM calls this through the Freestyle edge, which injects the real
// `x-coderouter-route-token` and `x-cmux-vm-id` headers; the guest itself
// only sends the public placeholder bearer.
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthFailure,
} from "../../../../../services/coderouter/routeTokenAuth";
import { findTeamMachine } from "../../../../../services/coderouter/teamMachines";
import { loadCoderouterVmMetrics } from "../../../../../services/coderouter/vmMetrics";
import { vmUsageResponse } from "../../../../../services/coderouter/vmUsageContract";
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "../../../../../services/coderouter/observability";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

// Same wording as the codex proxy's unauthorized responses.
const AUTH_FAILURE_MESSAGES: Record<RouteTokenAuthFailure, string> = {
  missing_route_token: "Sign in with `cr login` and retry.",
  invalid_route_token:
    "Your coderouter session expired or was revoked. Run `cr login` and retry.",
  vm_mismatch:
    "This machine's coderouter credential does not match the machine it was issued to.",
};

export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateRequestRouteToken(request);
  if (!auth.ok) {
    addCoderouterBreadcrumb("auth", "Route token rejected", {
      path: "vm_usage",
    }, "warning");
    captureCoderouterEvent({
      event: "coderouter_auth_rejected",
      properties: { surface: "vm_usage", reason: auth.reason },
    });
    return Response.json(
      {
        error: "unauthorized",
        message: AUTH_FAILURE_MESSAGES[auth.reason],
        retryable: false,
      },
      { status: 401, headers: JSON_HEADERS },
    );
  }
  const identity = auth.identity;
  if (identity.vmId === null) {
    return Response.json(
      {
        error: "vm_bound_token_required",
        message: "Per-machine usage is only available from inside a cmux Cloud VM.",
        retryable: false,
      },
      { status: 403, headers: JSON_HEADERS },
    );
  }
  let machine;
  try {
    machine = await findTeamMachine(identity.teamId, identity.vmId);
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "find_team_machine" });
    return Response.json(
      { error: "machine_lookup_unavailable", retryable: true },
      { status: 503, headers: { ...JSON_HEADERS, "retry-after": "5" } },
    );
  }
  if (!machine) {
    return Response.json({ error: "vm_not_found" }, {
      status: 404,
      headers: JSON_HEADERS,
    });
  }
  const metrics = await loadCoderouterVmMetrics(
    identity.teamId,
    machine.vmId,
    "vm_self_api",
  );
  return Response.json(vmUsageResponse(machine.vmId, metrics), {
    headers: JSON_HEADERS,
  });
}
