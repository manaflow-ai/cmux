import { provisionPublicationApi } from "../../../../services/vm-publications/apiKeys";
import { parseRequiredObjectBody, stringField } from "../../../../services/vms/routeInput";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  publicationGeneratedDomain,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../publications/routeShared";

export const maxDuration = 120;

export async function POST(request: Request): Promise<Response> {
  return withAuthedPublicationApiRoute(request, (context) => handleApiProvision(request, context));
}

const BODY_ACTION = "Send JSON with vmId, port, and optional accessMode (personal or team), teamId, name and expiresAt.";

/**
 * Provision an API on a Cloud VM: publish its port under a generated hostname
 * and answer the URL with a new API key in one call. Retrying with the same
 * machine and port reuses the publication and mints another key.
 */
export async function handleApiProvision(
  request: Request,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const parsed = await parseRequiredObjectBody(request, { operation: "API provision", action: BODY_ACTION });
  if (!parsed.ok) return parsed.response;
  const body = parsed.body ?? {};
  const vmId = stringField(body, "vmId");
  if (!vmId) {
    return jsonResponse({
      error: "vm_publication_invalid_request",
      message: "vmId is required.",
      action: "Run `cmux cloud list` and pass a running machine id.",
      details: { field: "vmId" },
    }, 400);
  }
  const provisioned = await context.run(provisionPublicationApi({
    principal: context.principal,
    providerVmId: vmId,
    port: typeof body.port === "number" ? body.port : Number.NaN,
    accessMode: stringField(body, "accessMode") as "personal" | "team" | undefined,
    teamId: stringField(body, "teamId"),
    name: body.name,
    expiresAt: body.expiresAt,
    forwardAuth: publicationForwardAuthConfig(environment),
    generatedDomain: publicationGeneratedDomain(environment),
  }));
  return jsonResponse(provisioned, 201, { "cache-control": "no-store" });
}
