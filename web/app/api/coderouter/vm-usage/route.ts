import { resolveCoderouterUsageTeam } from "../../../../services/coderouter/requestContext";
import { findTeamMachine } from "../../../../services/coderouter/teamMachines";
import { loadCoderouterVmMetrics } from "../../../../services/coderouter/vmMetrics";
import { vmUsageResponse } from "../../../../services/coderouter/vmUsageContract";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

export async function GET(request: Request): Promise<Response> {
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;
  const vmId = new URL(request.url).searchParams.get("vmId")?.trim() ?? "";
  if (!vmId) {
    return Response.json({ error: "invalid_request" }, {
      status: 400,
      headers: JSON_HEADERS,
    });
  }
  let machine;
  try {
    machine = await findTeamMachine(resolved.teamId, vmId);
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
    resolved.teamId,
    machine.vmId,
    "vm_usage_api",
  );
  return Response.json(vmUsageResponse(machine.vmId, metrics), {
    headers: JSON_HEADERS,
  });
}
