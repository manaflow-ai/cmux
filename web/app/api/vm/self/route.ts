// Self-discovery for a process inside a Cloud VM: which machine am I, and
// which machines does my team have. The guest has no Stack token; it reaches
// this through the Freestyle TLS edge, which injects the route token bound to
// the machine's `cloud_vms` row plus `x-cmux-vm-id`. That binding is the only
// credential, so a forged header or an unbound `cr` CLI token is refused.
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthFailure,
} from "../../../../services/coderouter/routeTokenAuth";
import { runVmRoute } from "../../../../services/vms/routeWorkflow";
import { discoverVmSelf } from "../../../../services/vms/workflows";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

const AUTH_FAILURE_MESSAGES: Record<RouteTokenAuthFailure, string> = {
  missing_route_token: "This endpoint is only reachable from inside a cmux Cloud VM.",
  invalid_route_token: "This machine's cmux credential expired or was revoked.",
  vm_mismatch: "This machine's cmux credential does not match the machine it was issued to.",
};

export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateRequestRouteToken(request);
  if (!auth.ok) {
    return Response.json(
      { error: "unauthorized", message: AUTH_FAILURE_MESSAGES[auth.reason], retryable: false },
      { status: 401, headers: JSON_HEADERS },
    );
  }
  const { teamId, vmId } = auth.identity;
  if (vmId === null) {
    return Response.json(
      {
        error: "vm_bound_token_required",
        message: "Self-discovery is only available from inside a cmux Cloud VM.",
        retryable: false,
      },
      { status: 403, headers: JSON_HEADERS },
    );
  }
  const run = await runVmRoute(discoverVmSelf({ teamId, vmId }), {
    request,
    onError: {
      // The guest contract predates the shared VM error shape: keep its flat
      // bodies and no-store header so the in-VM `cmux self` shim stays stable.
      VmDatabaseError: () =>
        Response.json(
          { error: "machine_lookup_unavailable", retryable: true },
          { status: 503, headers: { ...JSON_HEADERS, "retry-after": "5" } },
        ),
      VmNotFoundError: () =>
        Response.json({ error: "vm_not_found", retryable: false }, { status: 404, headers: JSON_HEADERS }),
    },
  });
  if (!run.ok) return run.response;
  const body = run.value;
  return Response.json(body, { headers: JSON_HEADERS });
}
