import {
  createPublication,
  listPublications,
} from "../../../../services/vm-publications/workflows";
import {
  parseRequiredObjectBody,
  stringField,
} from "../../../../services/vms/routeInput";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
  type PublicationWorkflowRunner,
} from "./routeShared";

export const maxDuration = 120;

export async function GET(request: Request): Promise<Response> {
  return withAuthedPublicationApiRoute(request, (context) =>
    handlePublicationList(context));
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedPublicationApiRoute(request, (context) =>
    handlePublicationCreate(request, context));
}

export async function handlePublicationList(
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
): Promise<Response> {
  const publications = await context.run(listPublications({
    principal: context.principal,
  }));
  return jsonResponse({ publications });
}

export async function handlePublicationCreate(
  request: Request,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const parsed = await parseRequiredObjectBody(request, {
    operation: "domain publish",
    action: "Send JSON with vmId, port, accessMode, and optional hostname and teamId.",
  });
  if (!parsed.ok) return parsed.response;
  const body = parsed.body;
  if (!body) {
    return jsonResponse({
      error: "vm_publication_invalid_request",
      message: "Cloud VM domain publish requires a JSON body.",
      action: "Send JSON with vmId, port, accessMode, and optional hostname and teamId.",
    }, 400);
  }
  const vmId = stringField(body, "vmId");
  const accessMode = stringField(body, "accessMode") ?? "personal";
  const hostname = stringField(body, "hostname");
  const teamId = stringField(body, "teamId");
  const port = body.port;
  if (!vmId) {
    return jsonResponse({
      error: "vm_publication_invalid_request",
      message: "vmId is required.",
      action: "Run `cmux cloud list` and pass a running machine id.",
      details: { field: "vmId" },
    }, 400);
  }
  const publication = await context.run(createPublication({
    principal: context.principal,
    providerVmId: vmId,
    port: typeof port === "number" ? port : Number.NaN,
    hostname,
    accessMode: accessMode as "personal" | "team" | "public",
    teamId,
    forwardAuth: publicationForwardAuthConfig(request, environment),
  }));
  return jsonResponse({ publication }, 201);
}

/** Test seam for route handlers without Stack or database credentials. */
export type { PublicationWorkflowRunner };
