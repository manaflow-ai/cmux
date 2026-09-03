import { resolveCoderouterUsageTeam } from "../../../../../services/coderouter/requestContext";
import { listTeamMachines } from "../../../../../services/coderouter/teamMachines";
import { loadCoderouterTeamMachineMetrics } from "../../../../../services/coderouter/vmMetrics";
import { teamVmUsageResponse } from "../../../../../services/coderouter/vmUsageContract";
import { reportCoderouterFailure } from "../../../../../services/coderouter/observability";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

export async function GET(request: Request): Promise<Response> {
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
  const metrics = await loadCoderouterTeamMachineMetrics(
    resolved.teamId,
    "team_machines_api",
  );
  return Response.json(teamVmUsageResponse(resolved.teamId, metrics, owned), {
    headers: JSON_HEADERS,
  });
}
