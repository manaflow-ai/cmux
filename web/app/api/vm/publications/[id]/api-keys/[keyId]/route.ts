import { revokePublicationApiKey } from "../../../../../../../services/vm-publications/apiKeys";
import { jsonResponse } from "../../../../../../../services/vms/routeHelpers";
import {
  publicationReference,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../../../routeShared";

export const maxDuration = 120;

type RouteContext = { readonly params: Promise<{ id: string; keyId: string }> };

export async function DELETE(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id, keyId } = await route.params;
    return handleApiKeyRevoke(id, keyId, context);
  });
}

/** Revoked keys fail the next request at the edge; no session or cache outlives it. */
export async function handleApiKeyRevoke(
  publicationId: string,
  keyId: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const apiKey = await context.run(revokePublicationApiKey({
    principal: context.principal,
    publicationId: publicationReference(publicationId, environment),
    keyId,
  }));
  return jsonResponse({ apiKey });
}
