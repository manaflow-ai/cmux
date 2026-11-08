import { readBoundedJsonRecord } from "../../../../../../services/subrouter/boundedJson";
import { resolveSubrouterRequestContext } from "../../../../../../services/subrouter/requestContext";
import { subrouterErrorResponse } from "../../../../../../services/subrouter/routeHelpers";
import type { SubrouterCredentialLeaseOutcome } from "../../../../../../services/subrouter/types";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";


type RouteContext = {
  readonly params: Promise<{ readonly leaseId: string }>;
};

const outcomes = new Set<SubrouterCredentialLeaseOutcome>([
  "success",
  "unauthorized",
  "rate_limited",
  "provider_error",
]);
const MAX_REQUEST_BYTES = 4 * 1024;

export async function POST(
  request: Request,
  routeContext: RouteContext,
): Promise<Response> {
  const { leaseId: rawLeaseId } = await routeContext.params;
  const leaseId = rawLeaseId.trim();
  if (!leaseId || leaseId.length > 200) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  const resolved = await resolveSubrouterRequestContext(request);
  if (!resolved.ok) return resolved.response;
  const context = resolved.value;

  const parsed = await readBoundedJsonRecord(request, MAX_REQUEST_BYTES);
  if (!parsed.ok) {
    return jsonResponse({ error: "invalid_request" }, parsed.status);
  }
  const body = parsed.value;
  if (!outcomes.has(body.outcome as SubrouterCredentialLeaseOutcome)) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }
  const statusCode = body.statusCode;
  if (
    statusCode !== undefined &&
    (typeof statusCode !== "number" ||
      !Number.isInteger(statusCode) ||
      statusCode < 100 ||
      statusCode > 599)
  ) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  try {
    const tenant = await context.client.exchangeTeam(
      context.accessToken,
      context.team,
    );
    const result = await context.client.reportCredentialLease(
      tenant.tenantKey,
      leaseId,
      {
        outcome: body.outcome as SubrouterCredentialLeaseOutcome,
        ...(typeof statusCode === "number" ? { statusCode } : {}),
      },
    );
    return jsonResponse(result);
  } catch (error) {
    return subrouterErrorResponse(error);
  }
}
