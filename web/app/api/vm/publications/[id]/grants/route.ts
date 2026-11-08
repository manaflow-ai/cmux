import { publicationApiCopy } from "../../../../../../services/vm-publications/copy";
import { listPublicationGrants, updatePublicationGrant } from "../../../../../../services/vm-publications/grants";
import { parseRequiredObjectBody, stringField } from "../../../../../../services/vms/routeInput";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import { publicationReference, withAuthedPublicationApiRoute, type AuthedPublicationRouteContext } from "../../routeShared";

type RouteContext = { readonly params: Promise<{ id: string }> };

export async function GET(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id } = await route.params;
    return jsonResponse({ grants: await context.run(listPublicationGrants({ principal: context.principal, publicationId: publicationReference(id) })) });
  });
}

export async function POST(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => handleGrantMutation(request, (await route.params).id, context));
}

export async function DELETE(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => handleGrantMutation(request, (await route.params).id, context));
}

export async function handleGrantMutation(request: Request, id: string, context: Pick<AuthedPublicationRouteContext, "principal" | "run">): Promise<Response> {
  const copy = publicationApiCopy("grant_body", request.headers.get("accept-language"));
  const parsed = await parseRequiredObjectBody(request, { operation: copy.message, action: copy.action });
  if (!parsed.ok) return parsed.response;
  return jsonResponse({ grant: await context.run(updatePublicationGrant({
    principal: context.principal, publicationId: publicationReference(id),
    email: parsed.body ? stringField(parsed.body, "email") ?? "" : "",
    expiresAt: parsed.body?.expiresAt,
    revoke: request.method === "DELETE",
  })) });
}
