import {
  deletePublication,
  updatePublicationAccess,
} from "../../../../../services/vm-publications/workflows";
import { parseRequiredObjectBody, stringField } from "../../../../../services/vms/routeInput";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  publicationReference,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../routeShared";

export const maxDuration = 120;

type RouteContext = { readonly params: Promise<{ id: string }> };

export async function PATCH(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id } = await route.params;
    return handlePublicationUpdate(request, id, context);
  });
}

export async function DELETE(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id } = await route.params;
    return handlePublicationDelete(id, context);
  });
}

export async function handlePublicationUpdate(
  request: Request,
  publicationId: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const parsed = await parseRequiredObjectBody(request, {
    operation: "domain access update",
    action: "Send JSON with accessMode and teamId only when using team access.",
  });
  if (!parsed.ok) return parsed.response;
  const body = parsed.body;
  const accessMode = body ? stringField(body, "accessMode") : undefined;
  if (!accessMode) {
    return jsonResponse({
      error: "vm_publication_invalid_request",
      message: "accessMode is required.",
      action: "Choose personal, team, or public; include teamId only with team.",
      details: { field: "accessMode" },
    }, 400);
  }
  const publication = await context.run(updatePublicationAccess({
    principal: context.principal,
    publicationId: publicationReference(publicationId, environment),
    accessMode: accessMode as "personal" | "team" | "public",
    teamId: body ? stringField(body, "teamId") : undefined,
    forwardAuth: publicationForwardAuthConfig(environment),
  }));
  return jsonResponse({ publication });
}

export async function handlePublicationDelete(
  publicationId: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const result = await context.run(deletePublication({
    principal: context.principal,
    publicationId: publicationReference(publicationId, environment),
  }));
  return jsonResponse(result);
}
