import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import { resolveCoderouterUsageTeam } from "../../../../../services/coderouter/requestContext";
import { listTeamMachines } from "../../../../../services/coderouter/teamMachines";
import { loadCoderouterTeamMachineMetrics } from "../../../../../services/coderouter/vmMetrics";
import { teamVmUsageResponse } from "../../../../../services/coderouter/vmUsageContract";
import { reportCoderouterFailure } from "../../../../../services/coderouter/observability";
import { isCoderouterViewOpenRequest } from "../../../../../services/coderouter/viewAnalytics";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

export const GET = coderouterControlRoute("vm_usage", "/api/coderouter/vm-usage/team", handleGet);

async function handleGet(request: Request): Promise<Response> {
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;
  let owned;
  try {
    owned = await listTeamMachines(resolved.teamId);
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "list_team_machines" });
    return Response.json(
      { error: "machine_lookup_unavailable", retryable: true },
      { status: 503, headers: { ...JSON_HEADERS, "retry-after": "5" } },
    );
  }
  // Clients poll machine usage; only the request that opened the view counts.
  const metrics = await loadCoderouterTeamMachineMetrics(
    resolved.teamId,
    "team_machines_api",
    { captureView: isCoderouterViewOpenRequest(request) },
  );
  return Response.json(teamVmUsageResponse(resolved.teamId, metrics, owned), {
    headers: JSON_HEADERS,
  });
}
